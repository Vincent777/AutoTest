#!/usr/bin/env python3
"""Place Prefill/Decode instances onto Ascend hosts with anti-colocation.

Policy (option B):
  - P and D must NOT share the same physical server.
  - Default: one PD instance per host (matches current one-SSH-executor-per-host).
  - Optional: same-role packing on one host if --allow-same-role-colocate and
    host has enough free GPU slots (advanced; off by default).

Examples:
  python3 pd_place_servers.py --topology 2P2D \\
    --candidates 10.9.1.86,10.9.1.94,10.9.1.78,10.9.1.106 \\
    --gpus-per-instance 2

  # Validate a placement / server_config style role map
  python3 pd_place_servers.py --validate-placement \\
    '10.9.1.86:prefill,10.9.1.94:prefill,10.9.1.78:decode,10.9.1.106:decode'
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import asdict, dataclass
from typing import Iterable

TOPOLOGY_RE = re.compile(r"^(\d+)[Pp](\d+)[Dd]$")


@dataclass(frozen=True)
class Placement:
    host: str
    role: str  # prefill | decode | proxy
    instance_id: str
    gpus: int


def parse_topology(topology: str) -> tuple[int, int]:
    m = TOPOLOGY_RE.match((topology or "").strip())
    if not m:
        raise ValueError(f"Invalid topology '{topology}', expected like 2P2D")
    n_p, n_d = int(m.group(1)), int(m.group(2))
    if n_p < 1 or n_d < 1:
        raise ValueError(f"Topology needs >=1P and >=1D, got {topology}")
    return n_p, n_d


def split_hosts(raw: str | Iterable[str] | None) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, str):
        parts = re.split(r"[,;\s]+", raw.strip())
        return [p for p in parts if p]
    return [str(x).strip() for x in raw if str(x).strip()]


def validate_no_pd_colocation(assignments: list[Placement] | list[tuple[str, str]]) -> None:
    """Reject any host that is assigned both prefill and decode."""
    roles_by_host: dict[str, set[str]] = defaultdict(set)
    for item in assignments:
        if isinstance(item, Placement):
            host, role = item.host, item.role
        else:
            host, role = item[0], item[1]
        role = role.strip().lower()
        if role not in {"prefill", "decode", "proxy"}:
            continue
        roles_by_host[host].add(role)

    bad = []
    for host, roles in sorted(roles_by_host.items()):
        if "prefill" in roles and "decode" in roles:
            bad.append(f"{host} has both prefill and decode ({sorted(roles)})")
    if bad:
        raise ValueError(
            "PD anti-colocation violated (P and D cannot share a server):\n  - "
            + "\n  - ".join(bad)
        )


def place_servers(
    *,
    topology: str,
    candidates: list[str],
    gpus_per_instance: int,
    host_free_gpus: dict[str, int] | None = None,
    host_roles: dict[str, str] | None = None,
    allow_same_role_colocate: bool = True,
) -> list[Placement]:
    """Assign hosts for P/D with cluster role affinity.

    - Prefer hosts already leased as the same role, then idle.
    - Never place Prefill on a decode host (or vice versa).
    - Default: allow packing multiple same-role instances on one host when GPUs allow.
    """
    n_p, n_d = parse_topology(topology)
    if gpus_per_instance < 1:
        raise ValueError("gpus_per_instance must be >= 1")

    roles = {h: (r or "idle").lower() for h, r in (host_roles or {}).items()}
    cand: list[str] = []
    seen: set[str] = set()
    for h in candidates:
        h = h.strip()
        if not h or h in seen:
            continue
        seen.add(h)
        free = (host_free_gpus or {}).get(h, gpus_per_instance)
        if free < gpus_per_instance:
            continue
        cand.append(h)

    def role_of(h: str) -> str:
        r = roles.get(h, "idle")
        return r if r in {"prefill", "decode", "idle"} else "idle"

    def ordered_for(role: str) -> list[str]:
        same = [h for h in cand if role_of(h) == role]
        idle = [h for h in cand if role_of(h) == "idle"]
        # opposite role excluded
        return same + idle

    free_left = {h: (host_free_gpus or {}).get(h, gpus_per_instance) for h in cand}
    # Track roles assigned in this placement pass (in addition to cluster leases)
    local_role: dict[str, str] = {}
    placements: list[Placement] = []

    def alloc(role: str, instance_id: str) -> Placement:
        for h in ordered_for(role):
            lr = local_role.get(h)
            if lr and lr != role:
                continue
            cr = role_of(h)
            if cr not in {"idle", role}:
                continue
            if free_left.get(h, 0) < gpus_per_instance:
                continue
            # Without packing: only one instance per host in this placement
            if not allow_same_role_colocate and h in local_role:
                continue
            free_left[h] -= gpus_per_instance
            local_role[h] = role
            roles[h] = role  # subsequent allocs in this call see the pin
            return Placement(
                host=h, role=role, instance_id=instance_id, gpus=gpus_per_instance
            )
        raise ValueError(
            f"Cannot place {role}/{instance_id} for {topology}: "
            f"no compatible host (need idle or {role}; P/D anti-colocation). "
            f"candidates={cand} roles={ {h: role_of(h) for h in cand} }"
        )

    for i in range(n_p):
        placements.append(alloc("prefill", f"p{i}"))
    for i in range(n_d):
        placements.append(alloc("decode", f"d{i}"))

    validate_no_pd_colocation(placements)
    return placements


def parse_placement_spec(spec: str) -> list[tuple[str, str]]:
    """Parse 'ip:role,ip:role,...' or lines 'ip role'."""
    items: list[tuple[str, str]] = []
    for part in re.split(r"[,;\n]+", spec.strip()):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            host, role, *_rest = part.split(":")
            items.append((host.strip(), role.strip().lower()))
        else:
            bits = part.split()
            if len(bits) < 2:
                raise ValueError(f"Bad placement token: {part}")
            items.append((bits[0], bits[1].lower()))
    return items


def format_shell(placements: list[Placement]) -> str:
    """host:role:instance_id,... for bash consumption."""
    return ",".join(f"{p.host}:{p.role}:{p.instance_id}" for p in placements)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--topology", default="", help="e.g. 2P2D")
    p.add_argument("--candidates", default="", help="Comma/space-separated host IPs")
    p.add_argument("--gpus-per-instance", type=int, default=1)
    p.add_argument(
        "--host-free-gpus",
        default="",
        help="Optional host:free_gpus pairs, e.g. 10.9.1.86:8,10.9.1.94:4",
    )
    p.add_argument(
        "--host-roles",
        default="",
        help="Cluster leases host:role pairs, e.g. 10.9.1.86:prefill,10.9.1.94:decode",
    )
    p.add_argument(
        "--allow-same-role-colocate",
        dest="allow_same_role_colocate",
        action="store_true",
        default=True,
        help="Allow multiple P (or D) on one host if GPUs allow (default: on)",
    )
    p.add_argument(
        "--no-same-role-colocate",
        dest="allow_same_role_colocate",
        action="store_false",
        help="Force one PD instance per host within this placement",
    )
    p.add_argument("--json", action="store_true", help="Print JSON array")
    p.add_argument(
        "--shell",
        action="store_true",
        help="Print host:role:instance_id,... (default)",
    )
    p.add_argument(
        "--validate-placement",
        default="",
        help="Validate placement spec only (host:role,...); exit 2 on P/D colocation",
    )
    p.add_argument(
        "--required-hosts",
        action="store_true",
        help="Print only required host count for topology (n_p+n_d) then exit",
    )
    args = p.parse_args(argv)

    try:
        if args.validate_placement:
            validate_no_pd_colocation(parse_placement_spec(args.validate_placement))
            print("OK: no P/D colocation")
            return 0

        if not args.topology:
            raise ValueError("--topology is required")

        if args.required_hosts:
            n_p, n_d = parse_topology(args.topology)
            # With same-role packing: at least one P host + one D host.
            print(2 if args.allow_same_role_colocate else (n_p + n_d))
            return 0

        free_map: dict[str, int] = {}
        if args.host_free_gpus.strip():
            for tok in re.split(r"[,;\s]+", args.host_free_gpus.strip()):
                if not tok:
                    continue
                host, free_s = tok.split(":", 1)
                free_map[host.strip()] = int(free_s)

        role_map: dict[str, str] = {}
        if args.host_roles.strip():
            for tok in re.split(r"[,;\s]+", args.host_roles.strip()):
                if not tok or ":" not in tok:
                    continue
                host, role = tok.split(":", 1)
                role_map[host.strip()] = role.strip().lower()

        placements = place_servers(
            topology=args.topology,
            candidates=split_hosts(args.candidates),
            gpus_per_instance=args.gpus_per_instance,
            host_free_gpus=free_map or None,
            host_roles=role_map or None,
            allow_same_role_colocate=args.allow_same_role_colocate,
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps([asdict(x) for x in placements], indent=2, ensure_ascii=False))
    else:
        # default shell format
        print(format_shell(placements))
        print(
            f"# topology={args.topology.upper()} hosts={len({x.host for x in placements})} "
            f"placements={len(placements)} (P/D anti-colocation OK)",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
