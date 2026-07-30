#!/usr/bin/env bash
# Phase 1 一键初始化：依赖、示例数据、干跑校验
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> llm_perf_dashboard bootstrap (Phase 1)"
echo "    root=$ROOT"

python3 -m pip install --user -q -r requirements.txt 2>/dev/null \
  || python3 -m pip install -q -r requirements.txt

mkdir -p storage artifacts results
chmod +x runners/*.sh runners/common/*.sh runners/common/resolve_release.py collector/ingest.py

echo "==> ingest sample data"
python3 collector/ingest.py collector/schema_example.json

echo "==> dry-run vllm"
bash runners/run_vllm.sh --dry-run

echo "==> dry-run sglang"
bash runners/run_sglang.sh --dry-run

echo "==> resolve latest release tags"
python3 runners/common/resolve_release.py --engine all --json || true

echo ""
echo "Bootstrap done."
echo "  Start WebUI:  bash scripts/start_dashboard.sh"
echo "  Weekly run:   bash runners/run_weekly.sh"
echo "  Real vLLM:    bash runners/run_vllm.sh --devices 0"
