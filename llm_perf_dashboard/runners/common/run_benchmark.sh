#!/usr/bin/env bash
# 对已启动的 OpenAI 兼容服务执行 workloads.yaml 中的压测，写出统一 JSON。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib.sh
source "${ROOT}/runners/common/lib.sh"

ENGINE=""
ENGINE_VERSION=""
MODEL_ID=""
HOST="127.0.0.1"
PORT=""
TOKENIZER=""
OUT_DIR=""
CONTAINER=""
HARDWARE="Ascend910B"

usage() {
  cat <<EOF
Usage: $0 --engine vllm|sglang --engine-version TAG --model MODEL_ID \\
          --host HOST --port PORT --tokenizer PATH --out-dir DIR [--container NAME]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2 ;;
    --engine-version) ENGINE_VERSION="$2"; shift 2 ;;
    --model) MODEL_ID="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --tokenizer) TOKENIZER="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --hardware) HARDWARE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

[[ -n "$ENGINE" && -n "$ENGINE_VERSION" && -n "$MODEL_ID" && -n "$PORT" && -n "$OUT_DIR" ]] || {
  usage; exit 1
}

mkdir -p "$OUT_DIR"
WORKDIR="${OUT_DIR}/bench_${ENGINE}_${MODEL_ID}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WORKDIR"

python3 - <<'PY' "$ROOT" "$ENGINE" "$ENGINE_VERSION" "$MODEL_ID" "$HOST" "$PORT" "$TOKENIZER" "$WORKDIR" "$HARDWARE" "$CONTAINER"
import json, os, re, shlex, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

import yaml

root, engine, engine_version, model, host, port, tokenizer, workdir, hardware, container = sys.argv[1:]
workloads_cfg = yaml.safe_load((Path(root) / "configs" / "workloads.yaml").read_text(encoding="utf-8"))
bench = workloads_cfg["benchmark"]
engine_cfg = workloads_cfg.get("engines", {}).get(engine, {})
results = []

def parse_metrics(text: str):
    mapping = {
        "Request throughput (req/s)": "request_throughput",
        "Output token throughput (tok/s)": "output_token_throughput",
        "Median TTFT (ms)": "ttft_p50_ms",
        "Mean TTFT (ms)": "ttft_p50_ms",
        "P99 TTFT (ms)": "ttft_p99_ms",
        "Median TPOT (ms)": "tpot_p50_ms",
        "Mean TPOT (ms)": "tpot_p50_ms",
        "P99 TPOT (ms)": "tpot_p99_ms",
    }
    out = {v: None for v in set(mapping.values())}
    out["success_rate"] = None
    for line in text.splitlines():
        s = line.strip()
        for prefix, key in mapping.items():
            if s.startswith(prefix):
                try:
                    out[key] = float(s.split(":")[-1].strip().split()[0])
                except Exception:
                    pass
    m_ok = re.search(r"Successful requests:\s+(\d+)", text)
    m_total = re.search(r"Total requests:\s+(\d+)", text)
    if m_ok and m_total:
        ok, total = int(m_ok.group(1)), int(m_total.group(1))
        out["success_rate"] = (ok / total) if total else None
    elif m_ok:
        out["success_rate"] = 1.0
    return out

if engine == "sglang":
    cmd_base = engine_cfg.get("command", "python3 -m sglang.bench_serving").split()
    backend = engine_cfg.get("backend", "sglang")
else:
    cmd_base = engine_cfg.get("command", bench.get("command", "vllm bench serve")).split()
    backend = engine_cfg.get("backend", bench.get("backend", "openai"))

for wl in workloads_cfg.get("workloads", []):
    if not wl.get("enabled", True):
        continue
    for conc in wl.get("concurrencies", [1]):
        started = datetime.now(timezone.utc).isoformat()
        args = cmd_base + [
            "--backend", backend,
            "--host", host,
            "--port", str(port),
            "--model", model,
            "--num-prompts", str(wl["num_prompts"]),
            "--request-rate", str(bench.get("request_rate", "inf")),
            "--max-concurrency", str(conc),
        ]
        if tokenizer:
            args += ["--tokenizer", tokenizer]
        if engine != "sglang" and bench.get("ignore_eos", True) and wl.get("dataset") == "random":
            args += ["--ignore-eos"]
        if wl.get("dataset") == "random":
            args += [
                "--dataset-name", "random",
                "--random-input-len", str(wl["input_len"]),
                "--random-output-len", str(wl["output_len"]),
            ]
            # SGLang random 采样依赖 ShareGPT；vLLM random 不能同时传 --dataset-path
            if engine == "sglang" and wl.get("dataset_path"):
                args += ["--dataset-path", wl["dataset_path"]]
            input_len, output_len = wl.get("input_len"), wl.get("output_len")
        else:
            args += [
                "--dataset-name", "sharegpt",
                "--dataset-path", wl["dataset_path"],
            ]
            input_len = output_len = None
        if engine != "sglang":
            args += ["--endpoint", bench.get("endpoint", "/v1/completions")]

        log_path = Path(workdir) / f"{wl['id']}_c{conc}.log"
        print("RUN:", " ".join(args), flush=True)
        if container:
            inner = " ".join(shlex.quote(a) for a in args)
            proc = subprocess.run(
                ["docker", "exec", container, "/bin/bash", "-lc", inner],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            log_path.write_text(proc.stdout, encoding="utf-8")
        else:
            with log_path.open("w", encoding="utf-8") as logf:
                proc = subprocess.run(args, stdout=logf, stderr=subprocess.STDOUT, text=True)
        text = log_path.read_text(encoding="utf-8", errors="replace")
        finished = datetime.now(timezone.utc).isoformat()
        metrics = parse_metrics(text)
        if proc.returncode != 0 and metrics.get("success_rate") is None:
            metrics["success_rate"] = 0.0
        rec = {
            "run_id": f"{engine}_{engine_version}_{model}_{wl['id']}_c{conc}_{started}",
            "engine": engine,
            "engine_version": engine_version,
            "model": model,
            "hardware": hardware,
            "workload": wl["id"],
            "concurrency": conc,
            "input_len": input_len,
            "output_len": output_len,
            "metrics": metrics,
            "started_at": started,
            "finished_at": finished,
            "artifacts_path": str(workdir),
            "bench_exit_code": proc.returncode,
        }
        results.append(rec)

out_json = Path(workdir) / "results.json"
out_json.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
print(out_json)
PY
