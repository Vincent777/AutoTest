#!/usr/bin/env python3
"""Cluster-wide host PD role leases (shared via .npu_locks).

Policy:
  host role ∈ {idle, prefill, decode}
  - new Prefill may only join idle or prefill hosts
  - new Decode  may only join idle or decode hosts
  - first lease sets role; last release returns host to idle
  - multiple CI jobs may stack same-role instances on one host

Storage: /home/s_limingge/.npu_locks/host_role_leases.json
Lock:    /home/s_limingge/.npu_locks/host_role_leases.lock  (flock)

Examples:
  python3 host_role_lease.py status
  python3 host_role_lease.py dump-roles          # host:role,...
  python3 host_role_lease.py acquire --host 10.9.1.86 --role prefill \\
      --lease-id sess1:0:p0 --session sess1
  python3 host_role_lease.py release --lease-id sess1:0:p0
  python3 host_role_lease.py release-session --session sess1
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

DEFAULT_DIR = Path("/home/s_limingge/.npu_locks")
LEASES_NAME = "host_role_leases.json"
LOCK_NAME = "host_role_leases.lock"
VALID_ROLES = {"prefill", "decode"}


def paths(lock_dir: Path) -> tuple[Path, Path]:
    lock_dir.mkdir(parents=True, exist_ok=True)
    return lock_dir / LEASES_NAME, lock_dir / LOCK_NAME


def load_state(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {"hosts": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"hosts": {}}
    if not isinstance(data, dict):
        return {"hosts": {}}
    data.setdefault("hosts", {})
    return data


def save_state(path: Path, data: dict[str, Any]) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def host_entry(data: dict[str, Any], host: str) -> dict[str, Any]:
    hosts = data.setdefault("hosts", {})
    ent = hosts.get(host)
    if not ent:
        ent = {"role": "idle", "refs": {}}
        hosts[host] = ent
    ent.setdefault("role", "idle")
    ent.setdefault("refs", {})
    return ent


def effective_role(ent: dict[str, Any]) -> str:
    refs = ent.get("refs") or {}
    if not refs:
        return "idle"
    role = (ent.get("role") or "idle").lower()
    return role if role in VALID_ROLES else "idle"


def acquire(data: dict[str, Any], host: str, role: str, lease_id: str, session_id: str) -> None:
    role = role.strip().lower()
    if role not in VALID_ROLES:
        raise ValueError(f"invalid role '{role}', want prefill|decode")
    if not host or not lease_id:
        raise ValueError("host and lease_id required")

    ent = host_entry(data, host)
    cur = effective_role(ent)
    if cur == "idle":
        ent["role"] = role
    elif cur != role:
        raise ValueError(
            f"host {host} is role={cur}, cannot acquire {role} "
            f"(P/D must not share a server; same-role stacking OK)"
        )

    refs: dict[str, Any] = ent.setdefault("refs", {})
    refs[lease_id] = {
        "role": role,
        "session_id": session_id or "",
        "timestamp": int(time.time()),
    }
    ent["role"] = role


def release_lease(data: dict[str, Any], lease_id: str) -> int:
    removed = 0
    hosts = data.get("hosts") or {}
    for host, ent in list(hosts.items()):
        refs = ent.get("refs") or {}
        if lease_id in refs:
            del refs[lease_id]
            removed += 1
        if not refs:
            ent["role"] = "idle"
            ent["refs"] = {}
    return removed


def release_session(data: dict[str, Any], session_id: str) -> int:
    removed = 0
    hosts = data.get("hosts") or {}
    for host, ent in list(hosts.items()):
        refs = ent.get("refs") or {}
        drop = [k for k, v in refs.items() if (v or {}).get("session_id") == session_id]
        for k in drop:
            del refs[k]
            removed += 1
        if not refs:
            ent["role"] = "idle"
            ent["refs"] = {}
    return removed


def release_prefix(data: dict[str, Any], prefix: str) -> int:
    removed = 0
    hosts = data.get("hosts") or {}
    for host, ent in list(hosts.items()):
        refs = ent.get("refs") or {}
        drop = [k for k in refs if k.startswith(prefix)]
        for k in drop:
            del refs[k]
            removed += 1
        if not refs:
            ent["role"] = "idle"
            ent["refs"] = {}
    return removed


def dump_roles(data: dict[str, Any]) -> str:
    parts = []
    for host, ent in sorted((data.get("hosts") or {}).items()):
        role = effective_role(ent)
        if role != "idle":
            parts.append(f"{host}:{role}")
        else:
            # still emit idle optionally? placement prefers explicit map; include idle for clarity
            parts.append(f"{host}:idle")
    return ",".join(parts)


def with_lock(lock_dir: Path, fn):
    leases_path, lock_path = paths(lock_dir)
    with open(lock_path, "a+", encoding="utf-8") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        try:
            data = load_state(leases_path)
            result = fn(data)
            save_state(leases_path, data)
            return result
        finally:
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument(
        "--lock-dir",
        default=str(DEFAULT_DIR),
        help=f"Shared lock dir (default {DEFAULT_DIR})",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="Print JSON lease state")
    sub.add_parser("dump-roles", help="Print host:role,... for placement")

    ac = sub.add_parser("acquire", help="Acquire / stack a host role lease")
    ac.add_argument("--host", required=True)
    ac.add_argument("--role", required=True, choices=sorted(VALID_ROLES))
    ac.add_argument("--lease-id", required=True)
    ac.add_argument("--session", default="")

    rel = sub.add_parser("release", help="Release one lease-id")
    rel.add_argument("--lease-id", required=True)

    rs = sub.add_parser("release-session", help="Release all leases for a session_id")
    rs.add_argument("--session", required=True)

    rp = sub.add_parser("release-prefix", help="Release leases whose id starts with prefix")
    rp.add_argument("--prefix", required=True)

    ga = sub.add_parser("get", help="Print effective role for one host")
    ga.add_argument("--host", required=True)

    args = p.parse_args(argv)
    lock_dir = Path(args.lock_dir)

    try:
        if args.cmd == "status":

            def _status(data):
                return data

            data = with_lock(lock_dir, _status)
            # with_lock saves; status shouldn't need rewrite but OK
            print(json.dumps(data, indent=2, ensure_ascii=False))
            return 0

        if args.cmd == "dump-roles":

            def _dump(data):
                return dump_roles(data)

            print(with_lock(lock_dir, _dump))
            return 0

        if args.cmd == "get":

            def _get(data):
                ent = host_entry(data, args.host)
                return effective_role(ent)

            print(with_lock(lock_dir, _get))
            return 0

        if args.cmd == "acquire":

            def _acq(data):
                acquire(data, args.host, args.role, args.lease_id, args.session)
                return effective_role(host_entry(data, args.host))

            role = with_lock(lock_dir, _acq)
            print(f"OK host={args.host} role={role} lease_id={args.lease_id}")
            return 0

        if args.cmd == "release":

            def _rel(data):
                return release_lease(data, args.lease_id)

            n = with_lock(lock_dir, _rel)
            print(f"OK released={n} lease_id={args.lease_id}")
            return 0

        if args.cmd == "release-session":

            def _rs(data):
                return release_session(data, args.session)

            n = with_lock(lock_dir, _rs)
            print(f"OK released={n} session={args.session}")
            return 0

        if args.cmd == "release-prefix":

            def _rp(data):
                return release_prefix(data, args.prefix)

            n = with_lock(lock_dir, _rp)
            print(f"OK released={n} prefix={args.prefix}")
            return 0

        print(f"unknown cmd {args.cmd}", file=sys.stderr)
        return 2
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
