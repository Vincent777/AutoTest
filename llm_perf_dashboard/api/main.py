#!/usr/bin/env python3
"""Minimal FastAPI for llm_perf_dashboard results."""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path
from typing import Any, Optional

import yaml
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

DB_PATH = ROOT / "storage" / "perf.db"
WEB_DIR = ROOT / "web"

ALLOWED_METRICS = {
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
}


def load_local() -> dict[str, Any]:
    path = ROOT / "configs" / "local.yaml"
    if path.exists():
        return yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    return {}


def get_conn() -> sqlite3.Connection:
    from collector.ingest import connect  # type: ignore

    return connect(DB_PATH)


app = FastAPI(title="LLM Perf Dashboard", version="0.1.0")


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/runs")
def list_runs(
    engine: Optional[str] = None,
    model: Optional[str] = None,
    limit: int = Query(100, ge=1, le=1000),
) -> list[dict[str, Any]]:
    sql = "SELECT * FROM runs WHERE 1=1"
    params: list[Any] = []
    if engine:
        sql += " AND engine = ?"
        params.append(engine)
    if model:
        sql += " AND model = ?"
        params.append(model)
    sql += " ORDER BY date(created_at) DESC, workload ASC, concurrency ASC, engine ASC, created_at DESC LIMIT ?"
    params.append(limit)
    with get_conn() as conn:
        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
    return [dict(r) for r in rows]


@app.get("/api/meta")
def meta(model: Optional[str] = None) -> dict[str, Any]:
    """Distinct filter values for UI dropdowns."""
    with get_conn() as conn:
        try:
            models = [r[0] for r in conn.execute(
                "SELECT DISTINCT model FROM runs WHERE model IS NOT NULL ORDER BY model"
            ).fetchall()]
            if model:
                workloads = [r[0] for r in conn.execute(
                    "SELECT DISTINCT workload FROM runs WHERE model = ? AND workload IS NOT NULL ORDER BY workload",
                    (model,),
                ).fetchall()]
                concurrencies = [r[0] for r in conn.execute(
                    "SELECT DISTINCT concurrency FROM runs WHERE model = ? ORDER BY concurrency",
                    (model,),
                ).fetchall()]
            else:
                workloads = [r[0] for r in conn.execute(
                    "SELECT DISTINCT workload FROM runs WHERE workload IS NOT NULL ORDER BY workload"
                ).fetchall()]
                concurrencies = [r[0] for r in conn.execute(
                    "SELECT DISTINCT concurrency FROM runs ORDER BY concurrency"
                ).fetchall()]
        except sqlite3.OperationalError as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {
        "models": models,
        "workloads": workloads,
        "concurrencies": concurrencies,
    }


def _require_filters(model: str, workload: str, concurrency: Optional[str]) -> int:
    if not model or not workload:
        raise HTTPException(status_code=400, detail="model and workload are required")
    if concurrency is None or str(concurrency).strip() == "":
        raise HTTPException(status_code=400, detail="concurrency is required")
    try:
        return int(concurrency)
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="concurrency must be an integer") from exc


@app.get("/api/compare")
def compare(
    model: str,
    workload: str,
    concurrency: Optional[str] = Query(None),
) -> dict[str, Any]:
    """Latest metrics per engine for the same model/workload/concurrency."""
    conc = _require_filters(model, workload, concurrency)
    sql = """
    SELECT * FROM runs
    WHERE model = ? AND workload = ? AND concurrency = ?
    ORDER BY created_at DESC
    """
    with get_conn() as conn:
        rows = [dict(r) for r in conn.execute(sql, (model, workload, conc)).fetchall()]
    latest: dict[str, dict[str, Any]] = {}
    for row in rows:
        eng = row["engine"]
        if eng not in latest:
            latest[eng] = row
    return {"model": model, "workload": workload, "concurrency": conc, "engines": latest}


@app.get("/api/trends")
def trends(
    engine: str,
    model: str,
    workload: str,
    concurrency: Optional[str] = Query(None),
    metric: str = "request_throughput",
) -> list[dict[str, Any]]:
    conc = _require_filters(model, workload, concurrency)
    if metric not in ALLOWED_METRICS:
        raise HTTPException(status_code=400, detail=f"metric must be one of {sorted(ALLOWED_METRICS)}")
    sql = f"""
    SELECT engine_version, created_at, {metric} AS value
    FROM runs
    WHERE engine = ? AND model = ? AND workload = ? AND concurrency = ?
    ORDER BY created_at ASC
    """
    with get_conn() as conn:
        rows = conn.execute(sql, (engine, model, workload, conc)).fetchall()
    return [dict(r) for r in rows]


@app.get("/api/trends/all")
def trends_all(
    metric: str = "request_throughput",
    model: Optional[str] = None,
    workload: Optional[str] = None,
    concurrency: Optional[str] = Query(None),
) -> dict[str, Any]:
    """Historical points for one metric, optionally filtered, grouped by engine.

    Returns every matching run (not latest-only). Same engine_version keeps all
    historical points as long as ingest used distinct run_id (job/session suffix).
    """
    if metric not in ALLOWED_METRICS:
        raise HTTPException(status_code=400, detail=f"metric must be one of {sorted(ALLOWED_METRICS)}")

    sql = f"""
    SELECT engine, engine_version, model, workload, concurrency, created_at, {metric} AS value
    FROM runs
    WHERE {metric} IS NOT NULL
    """
    params: list[Any] = []
    if model:
        sql += " AND model = ?"
        params.append(model)
    if workload:
        sql += " AND workload = ?"
        params.append(workload)
    if concurrency is not None and str(concurrency).strip() != "":
        try:
            conc = int(concurrency)
        except (TypeError, ValueError) as exc:
            raise HTTPException(status_code=400, detail="concurrency must be an integer") from exc
        sql += " AND concurrency = ?"
        params.append(conc)
    sql += " ORDER BY created_at ASC"

    with get_conn() as conn:
        rows = [dict(r) for r in conn.execute(sql, params).fetchall()]
    grouped: dict[str, list[dict[str, Any]]] = {"vllm": [], "sglang": []}
    for row in rows:
        eng = str(row.get("engine", "")).lower()
        if eng not in grouped:
            grouped[eng] = []
        grouped[eng].append(row)
    return {
        "metric": metric,
        "model": model,
        "workload": workload,
        "concurrency": concurrency,
        "series": grouped,
        "count": len(rows),
    }


RECORD_COLUMNS = [
    "run_id", "engine", "engine_version", "model", "hardware",
    "workload", "concurrency",
    "successful_requests", "request_throughput",
    "output_token_throughput", "total_token_throughput",
    "ttft_mean_ms", "ttft_p50_ms", "ttft_p99_ms",
    "tpot_mean_ms", "tpot_p50_ms", "tpot_p99_ms",
    "itl_mean_ms", "itl_p50_ms", "itl_p99_ms",
    "success_rate", "started_at", "created_at",
]

# Test date: prefer started_at, fall back to ingest time.
RECORD_DATE_EXPR = "date(COALESCE(started_at, created_at))"


@app.get("/api/records/meta")
def records_meta() -> dict[str, Any]:
    """Distinct filter values for the records list."""
    with get_conn() as conn:
        try:
            models = [r[0] for r in conn.execute(
                "SELECT DISTINCT model FROM runs WHERE model IS NOT NULL ORDER BY model"
            ).fetchall()]
            engine_versions = [r[0] for r in conn.execute(
                "SELECT DISTINCT engine_version FROM runs WHERE engine_version IS NOT NULL ORDER BY engine_version"
            ).fetchall()]
            dates = [r[0] for r in conn.execute(
                f"SELECT DISTINCT {RECORD_DATE_EXPR} AS d FROM runs WHERE d IS NOT NULL ORDER BY d DESC"
            ).fetchall()]
        except sqlite3.OperationalError as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"models": models, "engine_versions": engine_versions, "dates": dates}


@app.get("/api/records")
def records(
    model: Optional[str] = None,
    engine_version: Optional[str] = None,
    date: Optional[str] = None,
    limit: int = Query(500, ge=1, le=2000),
) -> dict[str, Any]:
    """Filtered raw records for the list view (model / engine_version / date)."""
    sql = f"SELECT {', '.join(RECORD_COLUMNS)}, {RECORD_DATE_EXPR} AS run_date FROM runs WHERE 1=1"
    params: list[Any] = []
    if model:
        sql += " AND model = ?"
        params.append(model)
    if engine_version:
        sql += " AND engine_version = ?"
        params.append(engine_version)
    if date:
        sql += f" AND {RECORD_DATE_EXPR} = ?"
        params.append(date)
    sql += " ORDER BY run_date DESC, engine ASC, workload ASC, concurrency ASC LIMIT ?"
    params.append(limit)
    with get_conn() as conn:
        try:
            rows = [dict(r) for r in conn.execute(sql, params).fetchall()]
        except sqlite3.OperationalError as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {"count": len(rows), "records": rows}


@app.get("/api/concurrency/meta")
def concurrency_meta(
    model: Optional[str] = None,
    engine: Optional[str] = None,
    engine_version: Optional[str] = None,
    date: Optional[str] = None,
) -> dict[str, Any]:
    """Cascading filter values for the concurrency bar-chart page."""
    with get_conn() as conn:
        def distinct(expr: str, order: str, conds: list[str], params: list[Any]) -> list[Any]:
            sql = f"SELECT DISTINCT {expr} AS v FROM runs WHERE v IS NOT NULL"
            for cond in conds:
                sql += f" AND {cond}"
            sql += f" ORDER BY {order}"
            return [r[0] for r in conn.execute(sql, params).fetchall()]

        try:
            models = distinct("model", "v", [], [])
            conds: list[str] = []
            params: list[Any] = []
            if model:
                conds.append("model = ?")
                params.append(model)
            engines = distinct("engine", "v", conds, params)
            if engine:
                conds.append("engine = ?")
                params.append(engine)
            engine_versions = distinct("engine_version", "v", conds, params)
            if engine_version:
                conds.append("engine_version = ?")
                params.append(engine_version)
            dates = distinct(RECORD_DATE_EXPR, "v DESC", conds, params)
            if date:
                conds.append(f"{RECORD_DATE_EXPR} = ?")
                params.append(date)
            workloads = distinct("workload", "v", conds, params)
        except sqlite3.OperationalError as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {
        "models": models,
        "engines": engines,
        "engine_versions": engine_versions,
        "dates": dates,
        "workloads": workloads,
    }


@app.get("/api/concurrency")
def concurrency_series(
    model: str,
    engine: str,
    engine_version: str,
    date: str,
    workload: str,
    metric: str = "request_throughput",
) -> dict[str, Any]:
    """One metric across all concurrencies for a given test round."""
    if metric not in ALLOWED_METRICS:
        raise HTTPException(status_code=400, detail=f"metric must be one of {sorted(ALLOWED_METRICS)}")
    if not (model and engine and engine_version and date and workload):
        raise HTTPException(status_code=400, detail="model, engine, engine_version, date and workload are required")
    sql = f"""
    SELECT engine, concurrency, created_at, run_id, {metric} AS value
    FROM runs
    WHERE model = ? AND engine = ? AND engine_version = ? AND {RECORD_DATE_EXPR} = ? AND workload = ?
      AND {metric} IS NOT NULL
    ORDER BY concurrency ASC, created_at DESC
    """
    with get_conn() as conn:
        try:
            rows = [dict(r) for r in conn.execute(sql, (model, engine, engine_version, date, workload)).fetchall()]
        except sqlite3.OperationalError as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc
    # Keep only the latest run per concurrency (rows are created_at DESC within each concurrency).
    points: list[dict[str, Any]] = []
    seen: set[int] = set()
    for row in rows:
        if row["concurrency"] in seen:
            continue
        seen.add(row["concurrency"])
        points.append(row)
    return {
        "metric": metric,
        "model": model,
        "engine": engine,
        "engine_version": engine_version,
        "date": date,
        "workload": workload,
        "points": points,
    }


@app.get("/")
def index() -> FileResponse:
    return FileResponse(
        WEB_DIR / "index.html",
        headers={"Cache-Control": "no-store"},
    )


if (WEB_DIR / "static").exists():
    app.mount("/static", StaticFiles(directory=str(WEB_DIR / "static")), name="static")


def main() -> None:
    import uvicorn

    local = load_local()
    api = local.get("api", {})
    uvicorn.run(
        "api.main:app",
        host=api.get("host", "0.0.0.0"),
        port=int(api.get("port", 8088)),
        reload=False,
        app_dir=str(ROOT),
    )


if __name__ == "__main__":
    main()
