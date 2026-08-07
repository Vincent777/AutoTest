#!/usr/bin/env python3
"""Generate Prometheus scrape config for PD (Prefill/Decode) disaggregation.

Intended for GitLab CI / web pipeline variables. Example (2P2D):

  python3 generate_prometheus_yaml.py \\
    --engine vllm \\
    --topology 2P2D \\
    --prefill-targets 10.9.1.86:20000,10.9.1.87:20000 \\
    --decode-targets 10.9.1.88:20000,10.9.1.89:20000 \\
    -o prometheus.yaml

CI env-style (same meaning):

  export PD_ENGINE=vllm
  export PD_TOPOLOGY=2P2D
  export PD_PREFILL_TARGETS=10.9.1.86:20000,10.9.1.87:20000
  export PD_DECODE_TARGETS=10.9.1.88:20000,10.9.1.89:20000
  python3 generate_prometheus_yaml.py --from-env -o prometheus.yaml

Topology string format: ``NpMd`` (e.g. ``2P2D``, ``1P4D``). Optional proxy:
``--proxy-targets host:port,...`` (count not enforced by topology).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Any

import yaml

TOPOLOGY_RE = re.compile(r"^(\d+)[Pp](\d+)[Dd]$")
HOSTPORT_RE = re.compile(r"^[^:\s]+:\d+$")


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
    )
    return header + body


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
        "--engine",
        default="",
        help="Engine name for job_name / labels: vllm | sglang (or custom)",
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
    if args.from_env:
        args = apply_from_env(args)
    else:
        # Still allow env fallback for empty CLI fields (CI convenience)
        args = apply_from_env(args)
        args.extra_engine = getattr(args, "extra_engine", None)

    try:
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
