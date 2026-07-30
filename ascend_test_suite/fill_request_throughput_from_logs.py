#!/usr/bin/env python3
"""Parse Request throughput from performance logs and backfill Excel reports.

Also regenerates Excel via WriteReportToExcel when --regenerate is set
(so future template columns including Request throughput are applied).

Examples:
  # only print parsed Request throughput
  python3 fill_request_throughput_from_logs.py \\
    --log logs/performance/11111/20260727_DeepSeek-R1-Distill-Qwen-32B_DynamicSplitFuseV2_swap-space.log

  # backfill existing Excel (writes column 'Request throughput' after Successful requests
  # for old-layout sheets, or fills the template column for new-layout sheets)
  python3 fill_request_throughput_from_logs.py \\
    --excel report_20260727/11111/DeepSeek-R1-Distill-Qwen-32B_DynamicSplitFuseV2_Swap-space.xlsx \\
    --log logs/performance/11111/20260727_DeepSeek-R1-Distill-Qwen-32B_DynamicSplitFuseV2_swap-space.log

  # regenerate Excel from log (recommended; uses updated template)
  TASK_START_TIME=20260727 python3 fill_request_throughput_from_logs.py \\
    --excel report_20260727/11111/DeepSeek-R1-Distill-Qwen-32B_DynamicSplitFuseV2_Swap-space.xlsx \\
    --log logs/performance/11111/20260727_DeepSeek-R1-Distill-Qwen-32B_DynamicSplitFuseV2_swap-space.log \\
    --regenerate
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Any

from openpyxl import load_workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side


def parse_perf_log(text: str, test_type: str = "Random") -> dict[tuple[str, int], dict[str, float]]:
    """Same keying as WriteReportToExcel: {(context, concurrency): metrics}."""
    results: dict[tuple[str, int], dict[str, float]] = {}
    current_config: dict[str, Any] = {}
    in_out_length_key = "SharedGPT" if test_type == "SharedGPT" else None
    concurrency_key: int | None = None

    matches = re.finditer(
        r"(Random Testing [^\n]+|Testing concurrency=[^\n]+|[\=]+ Serving Benchmark Result [\=]+.*?[\=]+)",
        text,
        re.DOTALL,
    )
    for match in matches:
        section = match.group(0)
        if test_type == "Random":
            input_output_match = re.search(
                r"Random Testing input=(\d+), output=(\d+)", section
            )
            if input_output_match:
                current_config["input"] = int(input_output_match.group(1))
                current_config["output"] = int(input_output_match.group(2))
                in_out_length_key = (
                    f"{current_config['input']}+{current_config['output']}"
                )

        concurrency_prompt_match = re.search(
            r"Testing concurrency=(\d+), prompts=(\d+)", section
        )
        if concurrency_prompt_match:
            concurrency_key = int(concurrency_prompt_match.group(1))
            if in_out_length_key is None:
                in_out_length_key = "SharedGPT"
            results[(in_out_length_key, concurrency_key)] = {}

        benchmark_match = re.search(
            r"[\=]+ Serving Benchmark Result [\=]+.*?[\=]+", section, re.DOTALL
        )
        if benchmark_match and in_out_length_key is not None and concurrency_key is not None:
            key = (in_out_length_key, concurrency_key)
            if key not in results:
                results[key] = {}
            for metric in re.finditer(
                r"(?P<key>[A-Za-z0-9\s\(\)/]+):\s+(?P<value>[0-9.]+)",
                benchmark_match.group(0),
            ):
                results[key][metric.group("key").strip()] = float(metric.group("value"))
    return results


def find_request_throughput_column(ws) -> int | None:
    for col in range(1, (ws.max_column or 16) + 1):
        val = ws.cell(5, col).value
        if val and "Request throughput" in str(val):
            return col
    return None


def ensure_request_throughput_column(ws) -> int:
    """Return column index for Request throughput; insert if missing (old layout)."""
    existing = find_request_throughput_column(ws)
    if existing:
        return existing

    # Old layout: insert after Successful requests (col 4)
    insert_at = 5
    ws.insert_cols(insert_at)

    # Fix top header merge for Serving Benchmark Result if present
    # Best-effort: set sub-header
    header_fill = PatternFill("solid", fgColor="FFD966")
    center = Alignment(horizontal="center", vertical="center")
    thin = Border(
        left=Side(style="thin"),
        right=Side(style="thin"),
        top=Side(style="thin"),
        bottom=Side(style="thin"),
    )
    cell = ws.cell(5, insert_at, value="Request throughput")
    cell.fill = header_fill
    cell.font = Font(bold=True)
    cell.alignment = center
    cell.border = thin
    return insert_at


def parse_batch_cell(value: Any) -> int | None:
    if value is None:
        return None
    m = re.match(r"\s*(\d+)", str(value))
    return int(m.group(1)) if m else None


def backfill_excel(excel_path: Path, log_path: Path, test_type: str = "Random") -> int:
    text = log_path.read_text(encoding="utf-8", errors="replace")
    parsed = parse_perf_log(text, test_type=test_type)
    wb = load_workbook(excel_path)
    ws = wb.active
    col = ensure_request_throughput_column(ws)

    current_context = None
    filled = 0
    for row in range(6, ws.max_row + 1):
        ctx = ws.cell(row, 2).value
        if ctx is not None:
            current_context = str(ctx)
        concurrency = parse_batch_cell(ws.cell(row, 3).value)
        if concurrency is None or current_context is None:
            continue
        # Skip empty metric rows
        if ws.cell(row, 4).value is None and ws.cell(row, 6).value is None and ws.cell(row, 5).value is None:
            # after insert, output throughput may have shifted; check a few cols
            if all(ws.cell(row, c).value is None for c in range(4, min(8, ws.max_column + 1))):
                continue
        key = (current_context, concurrency)
        metrics = parsed.get(key)
        if not metrics:
            continue
        req_tps = metrics.get("Request throughput (req/s)")
        if req_tps is None:
            continue
        cell = ws.cell(row, col, value=req_tps)
        cell.number_format = "0.00"
        filled += 1

    wb.save(excel_path)
    return filled


def regenerate_excel(excel_path: Path, log_path: Path, test_type: str = "Random") -> None:
    """Re-run WriteReportToExcel using metadata from existing Excel."""
    wb = load_workbook(excel_path, data_only=True)
    ws = wb.active
    model_name = ws.cell(1, 2).value or excel_path.stem
    exec_cmd = ws.cell(2, 2).value or ""
    test_cmd = ws.cell(3, 2).value or ""
    session_id = excel_path.parent.name
    engine_name = detect_engine_from_launch(str(exec_cmd))
    # Prefer existing Inference Engine cell if already set to a known engine
    cell_engine = ws.cell(6, 1).value
    if cell_engine and str(cell_engine).strip().lower() not in {"siginfer", ""}:
        # keep Excel display style if already meaningful; else map from launch
        engine_name = str(cell_engine).strip()

    # report_YYYYMMDD -> TASK_START_TIME
    report_dir = excel_path.parent.parent.name
    m = re.match(r"report_(\d{8})", report_dir)
    if m:
        os.environ["TASK_START_TIME"] = m.group(1)

    # Import locally so template changes are picked up
    from WriteReportToExcel import main as _unused  # noqa: F401
    import WriteReportToExcel as wre

    sys.argv = [
        "WriteReportToExcel.py",
        engine_name,
        test_type,
        str(model_name),
        session_id,
        str(exec_cmd),
        str(test_cmd),
        str(log_path),
    ]
    wre.main()


def detect_engine_from_launch(launch_cmd: str) -> str:
    text = (launch_cmd or "").lower()
    if "sglang" in text:
        return "SGLang"
    if "vllm" in text:
        return "vLLM"
    if "mindie" in text:
        return "MindIE"
    if "siginfer" in text:
        return "SigInfer"
    return "SigInfer"


def auto_find_log(excel_path: Path, suite_root: Path) -> Path | None:
    session = excel_path.parent.name
    report_dir = excel_path.parent.parent.name
    m = re.match(r"report_(\d{8})", report_dir)
    date = m.group(1) if m else None
    stem = excel_path.stem  # may have Swap-space
    candidates = []
    log_dir = suite_root / "logs" / "performance" / session
    if not log_dir.exists():
        return None
    for p in log_dir.glob("*.log"):
        if p.name.startswith("cron_job_"):
            continue
        # fuzzy match ignoring case
        if date and date not in p.name:
            continue
        if stem.lower().replace("_swap-space", "").replace("_use-prefix-cache", "") in p.name.lower().replace("_swap-space", "").replace("_use-prefix-cache", ""):
            candidates.append(p)
        elif "DeepSeek-R1-Distill-Qwen-32B" in stem and "DeepSeek-R1-Distill-Qwen-32B" in p.name:
            candidates.append(p)
    return candidates[0] if candidates else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--excel", action="append", default=[], help="Excel report path")
    parser.add_argument("--log", action="append", default=[], help="Performance log path (aligned with --excel)")
    parser.add_argument("--test-type", default="Random", choices=["Random", "SharedGPT"])
    parser.add_argument("--regenerate", action="store_true", help="Regenerate Excel via WriteReportToExcel")
    parser.add_argument("--print-only", action="store_true", help="Only print Request throughput from log")
    args = parser.parse_args()

    suite_root = Path(__file__).resolve().parent

    if args.print_only:
        logs = [Path(x) for x in args.log]
        if not logs and args.excel:
            for e in args.excel:
                found = auto_find_log(Path(e), suite_root)
                if found:
                    logs.append(found)
        for log in logs:
            parsed = parse_perf_log(log.read_text(encoding="utf-8", errors="replace"), args.test_type)
            print(f"==== {log}")
            for (ctx, conc), metrics in parsed.items():
                req = metrics.get("Request throughput (req/s)")
                if req is not None:
                    print(f"  ({ctx!r}, {conc}): {req}")
        return 0

    if not args.excel:
        parser.error("need --excel (or --print-only with --log)")

    for i, excel in enumerate(args.excel):
        excel_path = Path(excel).resolve()
        if i < len(args.log):
            log_path = Path(args.log[i]).resolve()
        else:
            log_path = auto_find_log(excel_path, suite_root)
            if not log_path:
                raise FileNotFoundError(f"cannot find performance log for {excel_path}")
        print(f"excel={excel_path}")
        print(f"log={log_path}")
        if args.regenerate:
            cwd = os.getcwd()
            os.chdir(suite_root)
            try:
                regenerate_excel(excel_path, log_path, args.test_type)
            finally:
                os.chdir(cwd)
            print("regenerated with Request throughput column")
        else:
            n = backfill_excel(excel_path, log_path, args.test_type)
            print(f"filled Request throughput in {n} row(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
