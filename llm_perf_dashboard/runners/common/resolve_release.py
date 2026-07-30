#!/usr/bin/env python3
"""Resolve latest release tags for vLLM-Ascend / SGLang (release-only policy)."""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[2]


def load_engines(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def fetch_releases(url: str, limit: int = 30) -> list[dict[str, Any]]:
    req = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "llm-perf-dashboard"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if not isinstance(data, list):
        raise RuntimeError(f"Unexpected releases payload from {url}")
    return data[:limit]


def is_allowed_tag(tag: str, policy: dict[str, Any]) -> bool:
    pattern = re.compile(policy.get("tag_regex", r"^v[0-9]+\.[0-9]+.*"))
    if not pattern.match(tag):
        return False
    for bad in policy.get("exclude_substrings", []):
        if bad in tag:
            return False
    return True


def pick_latest(engine_key: str, cfg: dict[str, Any], known_tags: set[str] | None = None) -> dict[str, Any]:
    engines = cfg["engines"]
    policy = cfg.get("release_policy", {})
    eng = engines[engine_key]
    releases = fetch_releases(eng["github_releases"])
    candidates: list[str] = []
    for rel in releases:
        tag = rel.get("tag_name") or ""
        if not is_allowed_tag(tag, policy):
            continue
        if known_tags is not None and tag in known_tags:
            continue
        candidates.append(tag)
        if len(candidates) >= int(policy.get("max_new_tags_per_run", 1)):
            break

    # 若本周没有「未跑过」的新 tag，仍返回当前最新允许 tag，便于强制复跑
    if not candidates:
        for rel in releases:
            tag = rel.get("tag_name") or ""
            if is_allowed_tag(tag, policy):
                candidates = [tag]
                break

    if not candidates:
        raise RuntimeError(f"No release tag found for {engine_key}")

    return {
        "engine": engine_key,
        "name": eng["name"],
        "image_repo": eng["image_repo"],
        "tag": candidates[0],
        "image": f"{eng['image_repo']}:{candidates[0]}",
        "candidates": candidates,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", choices=["vllm", "sglang", "all"], default="all")
    parser.add_argument(
        "--config",
        default=str(ROOT / "configs" / "engines.yaml"),
        help="Path to engines.yaml",
    )
    parser.add_argument(
        "--known-db",
        default="",
        help="Optional SQLite path; skip tags already present in runs table",
    )
    parser.add_argument("--json", action="store_true", help="Print JSON")
    args = parser.parse_args()

    cfg = load_engines(Path(args.config))
    known: set[str] = set()
    if args.known_db:
        try:
            import sqlite3

            conn = sqlite3.connect(args.known_db)
            rows = conn.execute("SELECT DISTINCT engine_version FROM runs").fetchall()
            known = {r[0] for r in rows if r[0]}
            conn.close()
        except Exception as exc:  # noqa: BLE001 — best-effort skip list
            print(f"warn: cannot read known tags from db: {exc}", file=sys.stderr)

    keys = ["vllm", "sglang"] if args.engine == "all" else [args.engine]
    out = []
    for key in keys:
        try:
            out.append(pick_latest(key, cfg, known_tags=known if args.known_db else None))
        except Exception as exc:  # noqa: BLE001
            out.append({"engine": key, "error": str(exc)})

    if args.json:
        print(json.dumps(out, indent=2, ensure_ascii=False))
    else:
        for item in out:
            if "error" in item:
                print(f"{item['engine']}: ERROR {item['error']}")
            else:
                print(f"{item['engine']}: {item['image']}")
    return 0 if all("error" not in x for x in out) else 1


if __name__ == "__main__":
    raise SystemExit(main())
