#!/usr/bin/env python3
"""SQLite schema + ingest unified run JSON into storage/perf.db."""

from __future__ import annotations

import argparse
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / "storage" / "perf.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL UNIQUE,
    engine TEXT NOT NULL,
    engine_version TEXT NOT NULL,
    model TEXT NOT NULL,
    hardware TEXT NOT NULL,
    workload TEXT NOT NULL,
    concurrency INTEGER NOT NULL,
    input_len INTEGER,
    output_len INTEGER,
    request_throughput REAL,
    output_token_throughput REAL,
    ttft_p50_ms REAL,
    ttft_p99_ms REAL,
    tpot_p50_ms REAL,
    tpot_p99_ms REAL,
    success_rate REAL,
    started_at TEXT,
    finished_at TEXT,
    artifacts_path TEXT,
    raw_json TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_runs_engine_model ON runs(engine, model);
CREATE INDEX IF NOT EXISTS idx_runs_created ON runs(created_at);
"""


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    return conn


def normalize_record(data: dict[str, Any]) -> dict[str, Any]:
    metrics = data.get("metrics") or {}
    run_id = data.get("run_id") or (
        f"{data.get('engine')}_{data.get('engine_version')}_{data.get('model')}_"
        f"{data.get('workload')}_c{data.get('concurrency')}_{data.get('started_at', '')}"
    )
    return {
        "run_id": run_id,
        "engine": data["engine"],
        "engine_version": data["engine_version"],
        "model": data["model"],
        "hardware": data.get("hardware", "Ascend910B"),
        "workload": data["workload"],
        "concurrency": int(data["concurrency"]),
        "input_len": data.get("input_len"),
        "output_len": data.get("output_len"),
        "request_throughput": metrics.get("request_throughput"),
        "output_token_throughput": metrics.get("output_token_throughput"),
        "ttft_p50_ms": metrics.get("ttft_p50_ms"),
        "ttft_p99_ms": metrics.get("ttft_p99_ms"),
        "tpot_p50_ms": metrics.get("tpot_p50_ms"),
        "tpot_p99_ms": metrics.get("tpot_p99_ms"),
        "success_rate": metrics.get("success_rate"),
        "started_at": data.get("started_at"),
        "finished_at": data.get("finished_at"),
        "artifacts_path": data.get("artifacts_path"),
        "raw_json": json.dumps(data, ensure_ascii=False),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }


def ingest_file(conn: sqlite3.Connection, path: Path) -> int:
    payload = json.loads(path.read_text(encoding="utf-8"))
    records = payload if isinstance(payload, list) else [payload]
    count = 0
    for item in records:
        row = normalize_record(item)
        conn.execute(
            """
            INSERT OR REPLACE INTO runs (
                run_id, engine, engine_version, model, hardware, workload, concurrency,
                input_len, output_len, request_throughput, output_token_throughput,
                ttft_p50_ms, ttft_p99_ms, tpot_p50_ms, tpot_p99_ms, success_rate,
                started_at, finished_at, artifacts_path, raw_json, created_at
            ) VALUES (
                :run_id, :engine, :engine_version, :model, :hardware, :workload, :concurrency,
                :input_len, :output_len, :request_throughput, :output_token_throughput,
                :ttft_p50_ms, :ttft_p99_ms, :tpot_p50_ms, :tpot_p99_ms, :success_rate,
                :started_at, :finished_at, :artifacts_path, :raw_json, :created_at
            )
            """,
            row,
        )
        count += 1
    conn.commit()
    return count


def parse_benchmark_text(text: str) -> dict[str, float | None]:
    """Best-effort parse of `vllm bench serve` / benchmark_serving stdout."""
    mapping = {
        "Request throughput (req/s)": "request_throughput",
        "Output token throughput (tok/s)": "output_token_throughput",
        "Mean TTFT (ms)": "ttft_p50_ms",  # fallback when p50 missing
        "Median TTFT (ms)": "ttft_p50_ms",
        "P99 TTFT (ms)": "ttft_p99_ms",
        "Mean TPOT (ms)": "tpot_p50_ms",
        "Median TPOT (ms)": "tpot_p50_ms",
        "P99 TPOT (ms)": "tpot_p99_ms",
    }
    out: dict[str, float | None] = {v: None for v in set(mapping.values())}
    out["success_rate"] = None
    for line in text.splitlines():
        line = line.strip()
        for prefix, key in mapping.items():
            if line.startswith(prefix):
                try:
                    out[key] = float(line.split(":")[-1].strip().split()[0])
                except (ValueError, IndexError):
                    pass
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_files", nargs="+", help="Unified result JSON file(s)")
    parser.add_argument("--db", default=str(DEFAULT_DB))
    args = parser.parse_args()

    conn = connect(Path(args.db))
    total = 0
    for f in args.json_files:
        n = ingest_file(conn, Path(f))
        print(f"ingested {n} record(s) from {f}")
        total += n
    print(f"total={total} db={args.db}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
