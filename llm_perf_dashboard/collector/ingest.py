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

METRIC_COLUMNS = (
    "successful_requests",
    "request_throughput",
    "output_token_throughput",
    "total_token_throughput",
    "ttft_mean_ms",
    "ttft_p50_ms",
    "ttft_p99_ms",
    "tpot_mean_ms",
    "tpot_p50_ms",
    "tpot_p99_ms",
    "itl_mean_ms",
    "itl_p50_ms",
    "itl_p99_ms",
    "success_rate",
)

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
    successful_requests REAL,
    request_throughput REAL,
    output_token_throughput REAL,
    total_token_throughput REAL,
    ttft_mean_ms REAL,
    ttft_p50_ms REAL,
    ttft_p99_ms REAL,
    tpot_mean_ms REAL,
    tpot_p50_ms REAL,
    tpot_p99_ms REAL,
    itl_mean_ms REAL,
    itl_p50_ms REAL,
    itl_p99_ms REAL,
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


def migrate(conn: sqlite3.Connection) -> None:
    """Add any missing metric columns on older DBs."""
    existing = {
        row[1] for row in conn.execute("PRAGMA table_info(runs)").fetchall()
    }
    if not existing:
        return
    for col in METRIC_COLUMNS:
        if col not in existing:
            conn.execute(f"ALTER TABLE runs ADD COLUMN {col} REAL")
    conn.commit()


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    migrate(conn)
    return conn


def normalize_record(data: dict[str, Any]) -> dict[str, Any]:
    metrics = data.get("metrics") or {}
    run_id = data.get("run_id") or (
        f"{data.get('engine')}_{data.get('engine_version')}_{data.get('model')}_"
        f"{data.get('workload')}_c{data.get('concurrency')}_{data.get('started_at', '')}"
    )
    row = {
        "run_id": run_id,
        "engine": data["engine"],
        "engine_version": data["engine_version"],
        "model": data["model"],
        "hardware": data.get("hardware", "Ascend910B"),
        "workload": data["workload"],
        "concurrency": int(data["concurrency"]),
        "input_len": data.get("input_len"),
        "output_len": data.get("output_len"),
        "started_at": data.get("started_at"),
        "finished_at": data.get("finished_at"),
        "artifacts_path": data.get("artifacts_path"),
        "raw_json": json.dumps(data, ensure_ascii=False),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    for col in METRIC_COLUMNS:
        row[col] = metrics.get(col)
    return row


def ingest_file(conn: sqlite3.Connection, path: Path) -> int:
    payload = json.loads(path.read_text(encoding="utf-8"))
    records = payload if isinstance(payload, list) else [payload]
    metric_cols = ", ".join(METRIC_COLUMNS)
    metric_binds = ", ".join(f":{c}" for c in METRIC_COLUMNS)
    count = 0
    for item in records:
        row = normalize_record(item)
        conn.execute(
            f"""
            INSERT OR REPLACE INTO runs (
                run_id, engine, engine_version, model, hardware, workload, concurrency,
                input_len, output_len, {metric_cols},
                started_at, finished_at, artifacts_path, raw_json, created_at
            ) VALUES (
                :run_id, :engine, :engine_version, :model, :hardware, :workload, :concurrency,
                :input_len, :output_len, {metric_binds},
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
        "Successful requests": "successful_requests",
        "Request throughput (req/s)": "request_throughput",
        "Output token throughput (tok/s)": "output_token_throughput",
        "Total Token throughput (tok/s)": "total_token_throughput",
        "Total token throughput (tok/s)": "total_token_throughput",
        "Mean TTFT (ms)": "ttft_mean_ms",
        "Median TTFT (ms)": "ttft_p50_ms",
        "P99 TTFT (ms)": "ttft_p99_ms",
        "Mean TPOT (ms)": "tpot_mean_ms",
        "Median TPOT (ms)": "tpot_p50_ms",
        "P99 TPOT (ms)": "tpot_p99_ms",
        "Mean ITL (ms)": "itl_mean_ms",
        "Median ITL (ms)": "itl_p50_ms",
        "P99 ITL (ms)": "itl_p99_ms",
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
    # Fallback: older logs without Median → use Mean for p50
    if out.get("ttft_p50_ms") is None and out.get("ttft_mean_ms") is not None:
        out["ttft_p50_ms"] = out["ttft_mean_ms"]
    if out.get("tpot_p50_ms") is None and out.get("tpot_mean_ms") is not None:
        out["tpot_p50_ms"] = out["tpot_mean_ms"]
    if out.get("itl_p50_ms") is None and out.get("itl_mean_ms") is not None:
        out["itl_p50_ms"] = out["itl_mean_ms"]
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
