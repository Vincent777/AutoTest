#!/usr/bin/env python3
"""PD router helpers: parse server_config, register proxy, build launch args."""

from __future__ import annotations

import argparse
import fcntl
import json
import re
import shlex
import sys
from collections import defaultdict
from dataclasses import asdict, dataclass, field
from pathlib import Path

SERVER_LINE_RE = re.compile(
    r"^(?P<ip>\d+\.\d+\.\d+\.\d+):(?P<job_id>[^:]+):(?P<rest>.+)$"
)
KV_RE = re.compile(r"^(?P<key>[a-zA-Z_][a-zA-Z0-9_]*)=(?P<val>.*)$")
DEFAULT_CONFIG = Path("/home/s_limingge/.npu_locks/server_config.txt")
DEFAULT_LOCK = Path("/home/s_limingge/.npu_locks/server_config.lock")


@dataclass
class ServerConfigEntry:
    ip: str
    job_id: str
    api_port: int
    prometheus_port: int | None = None
    master_port: int | None = None
    role: str = ""
    topology: str = ""
    engine: str = ""
    extra: dict[str, str] = field(default_factory=dict)


def parse_server_config_line(line: str) -> ServerConfigEntry | None:
    raw = line.strip()
    if not raw or raw.startswith("#"):
        return None
    m = SERVER_LINE_RE.match(raw)
    if not m:
        raise ValueError(f"Invalid server_config line: {raw}")
    ip, job_id, rest = m.group("ip"), m.group("job_id"), m.group("rest").strip()
    tokens = rest.split()
    if not tokens:
        raise ValueError(f"Missing ports in server_config line: {raw}")

    ports: list[int] = []
    kv: dict[str, str] = {}
    for tok in tokens:
        km = KV_RE.match(tok)
        if km:
            kv[km.group("key")] = km.group("val")
            continue
        if not tok.isdigit():
            raise ValueError(f"Unexpected token '{tok}' in server_config line: {raw}")
        ports.append(int(tok))

    return ServerConfigEntry(
        ip=ip,
        job_id=job_id,
        api_port=ports[0],
        prometheus_port=ports[1] if len(ports) > 1 else None,
        master_port=ports[2] if len(ports) > 2 else None,
        role=(kv.get("role") or "").strip().lower(),
        topology=(kv.get("topology") or "").strip(),
        engine=(kv.get("engine") or "").strip().lower(),
        extra={k: v for k, v in kv.items() if k not in {"role", "topology", "engine", "metrics_port"}},
    )


def load_entries(path: Path, job_id: str) -> list[ServerConfigEntry]:
    if not path.is_file():
        raise ValueError(f"server_config not found: {path}")
    entries: list[ServerConfigEntry] = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            entry = parse_server_config_line(line)
        except ValueError as exc:
            raise ValueError(f"{path}:{lineno}: {exc}") from exc
        if entry is None or entry.job_id != job_id:
            continue
        entries.append(entry)
    if not entries:
        raise ValueError(f"No server_config entries for job_id={job_id}")
    return entries


def endpoints_by_role(entries: list[ServerConfigEntry], role: str) -> list[ServerConfigEntry]:
    role = role.lower()
    out = [e for e in entries if e.role == role]
    out.sort(key=lambda e: (e.ip, e.api_port))
    return out


def register_proxy(
    config_path: Path,
    lock_path: Path,
    *,
    ip: str,
    job_id: str,
    api_port: int,
    topology: str,
    engine: str,
) -> None:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    if not config_path.exists():
        config_path.touch()

    prom_port = api_port + 1
    master_port = api_port + 2
    line = (
        f"{ip}:{job_id}:{api_port} {prom_port} {master_port} "
        f"role=proxy topology={topology} engine={engine}\n"
    )

    with open(lock_path, "a+", encoding="utf-8") as lock_fp:
        fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX)
        try:
            lines = config_path.read_text(encoding="utf-8").splitlines(keepends=True)
            kept = [
                ln
                for ln in lines
                if not (
                    ln.startswith(f"{ip}:{job_id}:")
                    and "role=proxy" in ln
                )
            ]
            kept.append(line)
            config_path.write_text("".join(kept), encoding="utf-8")
        finally:
            fcntl.flock(lock_fp.fileno(), fcntl.LOCK_UN)


def get_proxy(entries: list[ServerConfigEntry]) -> ServerConfigEntry:
    proxies = endpoints_by_role(entries, "proxy")
    if not proxies:
        raise ValueError("No proxy entry in server_config for this job")
    return proxies[-1]


def build_sglang_lb_cmd(entries: list[ServerConfigEntry], host: str, port: int) -> list[str]:
    prefills = endpoints_by_role(entries, "prefill")
    decodes = endpoints_by_role(entries, "decode")
    if not prefills or not decodes:
        raise ValueError("Need at least one prefill and one decode entry before launching router")

    cmd = [
        "python3",
        "-m",
        "sglang.srt.disaggregation.launch_lb",
        "--host",
        host,
        "--port",
        str(port),
    ]
    for p in prefills:
        cmd.extend(["--prefill", f"http://{p.ip}:{p.api_port}"])
    for d in decodes:
        cmd.extend(["--decode", f"http://{d.ip}:{d.api_port}"])
    return cmd


def build_vllm_proxy_cmd(entries: list[ServerConfigEntry], host: str, port: int) -> list[str]:
    prefills = endpoints_by_role(entries, "prefill")
    decodes = endpoints_by_role(entries, "decode")
    if not prefills or not decodes:
        raise ValueError("Need at least one prefill and one decode entry before launching router")

    script_candidates = [
        "/vllm-ascend/examples/disaggregate_prefill_v1/load_balance_proxy_server_example.py",
        "/workspace/examples/disaggregate_prefill_v1/load_balance_proxy_server_example.py",
        "examples/disaggregate_prefill_v1/load_balance_proxy_server_example.py",
    ]
    cmd = ["python3", "__SCRIPT__", "--host", host, "--port", str(port)]
    cmd.extend(["--prefiller-hosts", *[p.ip for p in prefills]])
    cmd.extend(["--prefiller-ports", *[str(p.api_port) for p in prefills]])
    cmd.extend(["--decoder-hosts", *[d.ip for d in decodes]])
    cmd.extend(["--decoder-ports", *[str(d.api_port) for d in decodes]])
    return cmd, script_candidates


def count_expected_pd_roles(topology: str) -> tuple[int, int]:
    m = re.match(r"^(\d+)[Pp](\d+)[Dd]$", (topology or "").strip())
    if not m:
        raise ValueError(f"Invalid topology: {topology}")
    return int(m.group(1)), int(m.group(2))


def main(argv: list[str] | None = None) -> int:
    # Shared flags must live on subparsers (parents=): argparse only accepts
    # parent optionals *before* the subcommand otherwise, but our callers use
    #   pd_router.py <cmd> --job-id ...
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    common.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    common.add_argument("--job-id", required=True)

    p = argparse.ArgumentParser(description="PD router / server_config helpers")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", parents=[common], help="List all entries as JSON")

    gp = sub.add_parser("get-proxy", parents=[common], help="Print proxy ip and api port")
    gp.add_argument("--json", action="store_true")

    rp = sub.add_parser("register-proxy", parents=[common], help="Append proxy line to server_config")
    rp.add_argument("--ip", required=True)
    rp.add_argument("--port", type=int, required=True)
    rp.add_argument("--topology", required=True)
    rp.add_argument("--engine", required=True)

    w = sub.add_parser("wait-pd-ready", parents=[common], help="Wait until P/D entries match topology")
    w.add_argument("--topology", required=True)
    w.add_argument("--timeout", type=int, default=600)

    sg = sub.add_parser("sglang-lb-cmd", parents=[common], help="Print SGLang launch_lb command JSON")
    sg.add_argument("--host", default="0.0.0.0")
    sg.add_argument("--port", type=int, required=True)

    vl = sub.add_parser("vllm-proxy-cmd", parents=[common], help="Print vLLM proxy command JSON")
    vl.add_argument("--host", default="0.0.0.0")
    vl.add_argument("--port", type=int, required=True)

    pe = sub.add_parser("print-endpoints", parents=[common], help="Print shell exports for router launch")
    pe.add_argument("--engine", choices=("sglang", "vllm"), default="sglang")

    args = p.parse_args(argv)

    try:
        if args.cmd == "wait-pd-ready":
            import time

            n_p, n_d = count_expected_pd_roles(args.topology)
            deadline = time.time() + args.timeout
            last_err = ""
            while time.time() < deadline:
                try:
                    entries = load_entries(args.config, args.job_id)
                except ValueError as exc:
                    last_err = str(exc)
                    time.sleep(2)
                    continue
                p_cnt = len(endpoints_by_role(entries, "prefill"))
                d_cnt = len(endpoints_by_role(entries, "decode"))
                if p_cnt == n_p and d_cnt == n_d:
                    print(f"OK prefill={p_cnt} decode={d_cnt} (topology={args.topology})")
                    return 0
                last_err = f"prefill={p_cnt} decode={d_cnt}"
                time.sleep(2)
            print(
                f"TIMEOUT waiting PD nodes (need P=={n_p} D=={n_d}, "
                f"last={last_err}; topology={args.topology})",
                file=sys.stderr,
            )
            return 1

        entries = load_entries(args.config, args.job_id)

        if args.cmd == "list":
            print(json.dumps([asdict(e) for e in entries], ensure_ascii=False, indent=2))
            return 0

        if args.cmd == "get-proxy":
            proxy = get_proxy(entries)
            if args.json:
                print(json.dumps(asdict(proxy), ensure_ascii=False))
            else:
                print(f"{proxy.ip} {proxy.api_port}")
            return 0

        if args.cmd == "register-proxy":
            register_proxy(
                args.config,
                args.lock,
                ip=args.ip,
                job_id=args.job_id,
                api_port=args.port,
                topology=args.topology,
                engine=args.engine,
            )
            print(f"registered proxy {args.ip}:{args.port}")
            return 0

        if args.cmd == "sglang-lb-cmd":
            cmd = build_sglang_lb_cmd(entries, args.host, args.port)
            print(json.dumps({"cmd": cmd}, ensure_ascii=False))
            return 0

        if args.cmd == "vllm-proxy-cmd":
            cmd, scripts = build_vllm_proxy_cmd(entries, args.host, args.port)
            print(json.dumps({"cmd": cmd, "script_candidates": scripts}, ensure_ascii=False))
            return 0

        if args.cmd == "print-endpoints":
            prefills = endpoints_by_role(entries, "prefill")
            decodes = endpoints_by_role(entries, "decode")
            eng = args.engine.lower()
            if eng == "sglang":
                parts = ["python3", "-m", "sglang.srt.disaggregation.launch_lb"]
                for p in prefills:
                    parts.extend(["--prefill", f"http://{p.ip}:{p.api_port}"])
                for d in decodes:
                    parts.extend(["--decode", f"http://{d.ip}:{d.api_port}"])
                # shlex.quote so callers can safely eval the line
                print("ROUTER_CMD=" + shlex.quote(json.dumps(parts)))
            else:
                payload = {
                    "prefiller_hosts": [p.ip for p in prefills],
                    "prefiller_ports": [p.api_port for p in prefills],
                    "decoder_hosts": [d.ip for d in decodes],
                    "decoder_ports": [d.api_port for d in decodes],
                }
                print("VLLM_PROXY=" + shlex.quote(json.dumps(payload)))
            if prefills:
                print(f"TOPOLOGY={shlex.quote(prefills[0].topology or '')}")
                print(f"ENGINE={shlex.quote(prefills[0].engine or eng)}")
            return 0

    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
