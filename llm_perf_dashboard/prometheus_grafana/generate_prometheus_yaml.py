#!/usr/bin/env python3
"""Generate Prometheus scrape config for PD (Prefill/Decode) disaggregation.

CLI / CI env example (2P2D):

  python3 generate_prometheus_yaml.py \\
    --engine vllm \\
    --topology 2P2D \\
    --prefill-targets 10.9.1.86:20000,10.9.1.87:20000 \\
    --decode-targets 10.9.1.88:20000,10.9.1.89:20000 \\
    -o prometheus.yaml

From ascend_test_suite server_config.txt (preferred for dynamic ports):

  python3 generate_prometheus_yaml.py \\
    --from-server-config /home/s_limingge/.npu_locks/server_config.txt \\
    --job-id PerformanceTest_Model_99917_0 \\
    -o prometheus.yaml

server_config line format (backward compatible)::

  IP:JOB_ID:PORT PROMETHEUS_PORT MASTER_PORT [role=..] [topology=..] [engine=..] [metrics_port=..]

Scrape target defaults to IP:PORT; override with metrics_port= if set.
Prometheus must be able to reach the IP written in server_config (typically 10.0.0.x).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

TOPOLOGY_RE = re.compile(r"^(\d+)[Pp](\d+)[Dd]$")
HOSTPORT_RE = re.compile(r"^[^:\s]+:\d+$")
SERVER_LINE_RE = re.compile(r"^([^:\s]+):([^:\s]+):(.+)$")
KV_RE = re.compile(r"^([A-Za-z_][\w]*)=(.*)$")

DEFAULT_SERVER_CONFIG = "/home/s_limingge/.npu_locks/server_config.txt"


def parse_topology(topology: str) -> tuple[int, int]:
    m = TOPOLOGY_RE.match((topology or "").strip())
    if not m:
        raise ValueError(
            f"Invalid topology '{topology}'. Expected like 2P2D / 1P4D (case-insensitive)."
        )
    n_prefill, n_decode = int(m.group(1)), int(m.group(2))
    if n_prefill < 1 or n_decode < 1:
        raise ValueError(f"Topology must have at least 1P and 1D, got {topology}")
    return n_prefill, n_decode


def split_targets(raw: str | None) -> list[str]:
    if not raw or not str(raw).strip():
        return []
    items = []
    for part in re.split(r"[,;\s]+", str(raw).strip()):
        if not part:
            continue
        items.append(part.strip())
    return items


def validate_hostports(targets: list[str], label: str) -> None:
    bad = [t for t in targets if not HOSTPORT_RE.match(t)]
    if bad:
        raise ValueError(
            f"Invalid {label} target(s) (want host:port): {', '.join(bad)}"
        )


def build_static_configs(
    *,
    role: str,
    targets: list[str],
    topology: str,
    engine: str,
    extra_labels: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    """One static_config block per target so instance_id/role stay distinguishable."""
    prefix = {"prefill": "p", "decode": "d", "proxy": "proxy"}.get(role, role)
    configs: list[dict[str, Any]] = []
    for idx, target in enumerate(targets):
        labels = {
            "role": role,
            "instance_id": f"{prefix}{idx}" if role != "proxy" else f"proxy{idx}",
            "topology": topology,
            "engine": engine,
        }
        if extra_labels:
            labels.update(extra_labels)
        configs.append({"targets": [target], "labels": labels})
    return configs


def build_scrape_job(
    *,
    engine: str,
    topology: str,
    prefill: list[str],
    decode: list[str],
    proxy: list[str],
    metrics_path: str,
    job_suffix: str = "pd",
) -> dict[str, Any]:
    n_p, n_d = parse_topology(topology)
    if len(prefill) != n_p:
        raise ValueError(
            f"topology {topology} expects {n_p} prefill target(s), got {len(prefill)}: {prefill}"
        )
    if len(decode) != n_d:
        raise ValueError(
            f"topology {topology} expects {n_d} decode target(s), got {len(decode)}: {decode}"
        )
    validate_hostports(prefill, "prefill")
    validate_hostports(decode, "decode")
    validate_hostports(proxy, "proxy")

    engine_key = engine.strip().lower()
    static_configs: list[dict[str, Any]] = []
    static_configs.extend(
        build_static_configs(
            role="prefill", targets=prefill, topology=topology.upper(), engine=engine_key
        )
    )
    static_configs.extend(
        build_static_configs(
            role="decode", targets=decode, topology=topology.upper(), engine=engine_key
        )
    )
    if proxy:
        static_configs.extend(
            build_static_configs(
                role="proxy", targets=proxy, topology=topology.upper(), engine=engine_key
            )
        )

    return {
        "job_name": f"{engine_key}-{job_suffix}",
        "metrics_path": metrics_path,
        "static_configs": static_configs,
    }


def build_monolith_job(
    *,
    engine: str,
    targets: list[str],
    metrics_path: str,
) -> dict[str, Any]:
    """Non-PD: single / multi targets without role labels beyond engine."""
    validate_hostports(targets, engine)
    if not targets:
        raise ValueError(f"No targets for engine {engine}")
    engine_key = engine.strip().lower()
    return {
        "job_name": engine_key,
        "metrics_path": metrics_path,
        "static_configs": [
            {
                "targets": [t],
                "labels": {"engine": engine_key, "instance_id": f"n{i}"},
            }
            for i, t in enumerate(targets)
        ],
    }


def build_prometheus_config(
    jobs: list[dict[str, Any]],
    *,
    scrape_interval: str = "5s",
    evaluation_interval: str = "30s",
) -> dict[str, Any]:
    return {
        "global": {
            "scrape_interval": scrape_interval,
            "evaluation_interval": evaluation_interval,
        },
        "scrape_configs": jobs,
    }


def dump_yaml(cfg: dict[str, Any]) -> str:
    # Keep quotes on host:port for Prometheus friendliness / readability.
    class _Dumper(yaml.SafeDumper):
        pass

    def _str_representer(dumper: yaml.SafeDumper, data: str) -> Any:
        if HOSTPORT_RE.match(data) or data.endswith("s") and data[:-1].isdigit():
            return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="'")
        return dumper.represent_scalar("tag:yaml.org,2002:str", data)

    _Dumper.add_representer(str, _str_representer)
    body = yaml.dump(
        cfg,
        Dumper=_Dumper,
        default_flow_style=False,
        sort_keys=False,
        allow_unicode=True,
    )
    header = (
        "# Auto-generated by generate_prometheus_yaml.py — do not edit by hand.\n"
        "# Reload Prometheus after replace: curl -X POST http://localhost:9090/-/reload\n"
        "# Note: scrape IPs come from server_config (often 10.0.0.x); Prometheus must reach them.\n"
    )
    return header + body


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
    metrics_port: int | None = None
    extra: dict[str, str] = field(default_factory=dict)

    @property
    def scrape_port(self) -> int:
        if self.metrics_port is not None:
            return self.metrics_port
        return self.api_port

    @property
    def scrape_target(self) -> str:
        return f"{self.ip}:{self.scrape_port}"


def parse_server_config_line(line: str) -> ServerConfigEntry | None:
    raw = line.strip()
    if not raw or raw.startswith("#"):
        return None
    m = SERVER_LINE_RE.match(raw)
    if not m:
        raise ValueError(f"Invalid server_config line: {raw}")
    ip, job_id, rest = m.group(1), m.group(2), m.group(3).strip()
    tokens = rest.split()
    if not tokens:
        raise ValueError(f"Missing ports in server_config line: {raw}")

    ports: list[int] = []
    kv: dict[str, str] = {}
    for tok in tokens:
        km = KV_RE.match(tok)
        if km:
            kv[km.group(1)] = km.group(2)
            continue
        if not tok.isdigit():
            raise ValueError(f"Unexpected token '{tok}' in server_config line: {raw}")
        ports.append(int(tok))

    if not ports:
        raise ValueError(f"No API port in server_config line: {raw}")

    metrics_port = int(kv["metrics_port"]) if "metrics_port" in kv and kv["metrics_port"].isdigit() else None
    return ServerConfigEntry(
        ip=ip,
        job_id=job_id,
        api_port=ports[0],
        prometheus_port=ports[1] if len(ports) > 1 else None,
        master_port=ports[2] if len(ports) > 2 else None,
        role=(kv.get("role") or "").strip().lower(),
        topology=(kv.get("topology") or "").strip(),
        engine=(kv.get("engine") or "").strip().lower(),
        metrics_port=metrics_port,
        extra={k: v for k, v in kv.items() if k not in {"role", "topology", "engine", "metrics_port"}},
    )


def load_server_config(path: Path, job_id: str | None = None) -> list[ServerConfigEntry]:
    if not path.is_file():
        raise ValueError(f"server_config not found: {path}")
    entries: list[ServerConfigEntry] = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            entry = parse_server_config_line(line)
        except ValueError as exc:
            raise ValueError(f"{path}:{lineno}: {exc}") from exc
        if entry is None:
            continue
        if job_id and entry.job_id != job_id:
            continue
        entries.append(entry)
    if job_id and not entries:
        raise ValueError(f"No server_config entries for job_id={job_id} in {path}")
    if not entries:
        raise ValueError(f"No usable entries in {path}")
    return entries


def validate_pd_anti_colocation(entries: list[ServerConfigEntry]) -> None:
    """P and D must not share the same host IP (physical server)."""
    roles_by_ip: dict[str, set[str]] = defaultdict(set)
    for e in entries:
        if e.role in {"prefill", "decode"}:
            roles_by_ip[e.ip].add(e.role)
    bad = [
        f"{ip} has both prefill and decode"
        for ip, roles in sorted(roles_by_ip.items())
        if "prefill" in roles and "decode" in roles
    ]
    if bad:
        raise ValueError(
            "PD anti-colocation violated (P/D cannot share a server): " + "; ".join(bad)
        )


def jobs_from_server_config(
    entries: list[ServerConfigEntry],
    *,
    metrics_path: str,
    default_engine: str = "",
) -> list[dict[str, Any]]:
    """Build scrape jobs from server_config entries (PD and/or monolith)."""
    validate_pd_anti_colocation(entries)
    by_engine: dict[str, list[ServerConfigEntry]] = defaultdict(list)
    for e in entries:
        eng = e.engine or default_engine or "unknown"
        by_engine[eng].append(e)

    jobs: list[dict[str, Any]] = []
    for engine, group in by_engine.items():
        pd_entries = [e for e in group if e.role in {"prefill", "decode", "proxy"}]
        mono_entries = [e for e in group if e.role not in {"prefill", "decode", "proxy"}]

        if pd_entries:
            topologies = {e.topology.upper() for e in pd_entries if e.topology}
            if not topologies:
                raise ValueError(
                    f"engine={engine}: PD roles present but topology= missing on server_config lines"
                )
            if len(topologies) > 1:
                raise ValueError(
                    f"engine={engine}: conflicting topologies in server_config: {sorted(topologies)}"
                )
            topology = next(iter(topologies))
            prefill = [e.scrape_target for e in pd_entries if e.role == "prefill"]
            decode = [e.scrape_target for e in pd_entries if e.role == "decode"]
            proxy = [e.scrape_target for e in pd_entries if e.role == "proxy"]
            jobs.append(
                build_scrape_job(
                    engine=engine,
                    topology=topology,
                    prefill=prefill,
                    decode=decode,
                    proxy=proxy,
                    metrics_path=metrics_path,
                )
            )

        if mono_entries:
            jobs.append(
                build_monolith_job(
                    engine=engine,
                    targets=[e.scrape_target for e in mono_entries],
                    metrics_path=metrics_path,
                )
            )
    return jobs


def env_or_none(name: str) -> str | None:
    v = os.environ.get(name)
    if v is None:
        return None
    v = v.strip()
    return v if v else None


def apply_from_env(ns: argparse.Namespace) -> argparse.Namespace:
    """Fill missing CLI fields from PD_* / PROMETHEUS_* CI variables."""
    mapping = {
        "engine": "PD_ENGINE",
        "topology": "PD_TOPOLOGY",
        "prefill_targets": "PD_PREFILL_TARGETS",
        "decode_targets": "PD_DECODE_TARGETS",
        "proxy_targets": "PD_PROXY_TARGETS",
        "targets": "PD_TARGETS",
        "scrape_interval": "PROMETHEUS_SCRAPE_INTERVAL",
        "evaluation_interval": "PROMETHEUS_EVALUATION_INTERVAL",
        "metrics_path": "PROMETHEUS_METRICS_PATH",
        "output": "PROMETHEUS_OUTPUT",
        "server_config": "PD_SERVER_CONFIG",
        "job_id": "PD_JOB_ID",
    }
    for attr, env_name in mapping.items():
        cur = getattr(ns, attr, None)
        if cur is None or (isinstance(cur, str) and cur == ""):
            env_val = env_or_none(env_name)
            if env_val is not None:
                setattr(ns, attr, env_val)
    # Optional second engine block from env (vLLM + SGLang in one file)
    ns.extra_engine = env_or_none("PD_ENGINE_2")
    ns.extra_topology = env_or_none("PD_TOPOLOGY_2") or getattr(ns, "topology", None)
    ns.extra_prefill = env_or_none("PD_PREFILL_TARGETS_2")
    ns.extra_decode = env_or_none("PD_DECODE_TARGETS_2")
    ns.extra_proxy = env_or_none("PD_PROXY_TARGETS_2")
    ns.extra_targets = env_or_none("PD_TARGETS_2")
    return ns


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--from-env",
        action="store_true",
        help="Read PD_ENGINE / PD_TOPOLOGY / PD_PREFILL_TARGETS / PD_DECODE_TARGETS / ... from env",
    )
    p.add_argument(
        "--from-server-config",
        dest="server_config",
        default="",
        help=f"Path to server_config.txt (default when flag used alone: {DEFAULT_SERVER_CONFIG})",
        nargs="?",
        const=DEFAULT_SERVER_CONFIG,
    )
    p.add_argument(
        "--job-id",
        default="",
        help="Only use server_config lines matching this JOB_ID",
    )
    p.add_argument(
        "--engine",
        default="",
        help="Engine name for job_name / labels: vllm | sglang (or default for lines missing engine=)",
    )
    p.add_argument(
        "--topology",
        default="",
        help="PD topology, e.g. 2P2D. Empty = non-PD monolith mode (--targets)",
    )
    p.add_argument(
        "--prefill-targets",
        default="",
        help="Comma/space-separated prefill host:port list",
    )
    p.add_argument(
        "--decode-targets",
        default="",
        help="Comma/space-separated decode host:port list",
    )
    p.add_argument(
        "--proxy-targets",
        default="",
        help="Optional PD router/proxy host:port list",
    )
    p.add_argument(
        "--targets",
        default="",
        help="Non-PD targets (host:port,...) when --topology is empty",
    )
    p.add_argument("--scrape-interval", default="5s")
    p.add_argument("--evaluation-interval", default="30s")
    p.add_argument("--metrics-path", default="/metrics")
    p.add_argument(
        "-o",
        "--output",
        default="",
        help="Output path (default: stdout)",
    )
    p.add_argument(
        "--print-summary",
        action="store_true",
        help="Print human summary to stderr",
    )
    return p.parse_args(argv)


def jobs_from_args(args: argparse.Namespace) -> list[dict[str, Any]]:
    jobs: list[dict[str, Any]] = []

    def add_one(
        engine: str,
        topology: str | None,
        prefill_raw: str | None,
        decode_raw: str | None,
        proxy_raw: str | None,
        targets_raw: str | None,
    ) -> None:
        if not engine:
            raise ValueError("engine is required (CLI --engine or env PD_ENGINE)")
        topology = (topology or "").strip()
        if topology:
            jobs.append(
                build_scrape_job(
                    engine=engine,
                    topology=topology,
                    prefill=split_targets(prefill_raw),
                    decode=split_targets(decode_raw),
                    proxy=split_targets(proxy_raw),
                    metrics_path=args.metrics_path,
                )
            )
        else:
            jobs.append(
                build_monolith_job(
                    engine=engine,
                    targets=split_targets(targets_raw),
                    metrics_path=args.metrics_path,
                )
            )

    add_one(
        args.engine,
        args.topology,
        args.prefill_targets,
        args.decode_targets,
        args.proxy_targets,
        args.targets,
    )

    # Optional second engine from env (PD_ENGINE_2 / ...)
    extra_engine = getattr(args, "extra_engine", None)
    if extra_engine:
        add_one(
            extra_engine,
            getattr(args, "extra_topology", None),
            getattr(args, "extra_prefill", None),
            getattr(args, "extra_decode", None),
            getattr(args, "extra_proxy", None),
            getattr(args, "extra_targets", None),
        )
    return jobs


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    args = apply_from_env(args)

    try:
        server_config = (getattr(args, "server_config", None) or "").strip()
        if server_config:
            entries = load_server_config(
                Path(server_config),
                job_id=(args.job_id or "").strip() or None,
            )
            jobs = jobs_from_server_config(
                entries,
                metrics_path=args.metrics_path,
                default_engine=(args.engine or "").strip(),
            )
        else:
            jobs = jobs_from_args(args)

        cfg = build_prometheus_config(
            jobs,
            scrape_interval=args.scrape_interval,
            evaluation_interval=args.evaluation_interval,
        )
        text = dump_yaml(cfg)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if args.print_summary:
        for job in cfg["scrape_configs"]:
            n = sum(len(sc.get("targets", [])) for sc in job.get("static_configs", []))
            print(f"job={job['job_name']} targets={n}", file=sys.stderr)

    out = (args.output or "").strip()
    if out:
        path = Path(out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print(f"Wrote {path}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
