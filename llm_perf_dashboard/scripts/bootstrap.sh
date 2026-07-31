#!/usr/bin/env bash
# 一键初始化：依赖、示例数据
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> llm_perf_dashboard bootstrap"
echo "    root=$ROOT"

python3 -m pip install --user -q -r requirements.txt 2>/dev/null \
  || python3 -m pip install -q -r requirements.txt

mkdir -p storage artifacts results
chmod +x runners/*.sh runners/common/*.sh collector/ingest.py collector/excel_to_json.py 2>/dev/null || true

echo "==> ingest sample data"
python3 collector/ingest.py collector/schema_example.json

echo ""
echo "Bootstrap done."
echo "  Start WebUI:     bash scripts/start_dashboard.sh"
echo "  Local vLLM:      bash runners/run_vllm.sh"
echo "  Local SGLang:    bash runners/run_sglang.sh"
echo "  Local both:      bash runners/run_weekly.sh"
echo "  CI SSH helper:   bash runners/ci_ssh_perf.sh vLLM|SGLang"
echo ""
echo "  GitLab jobs: vLLM_Perf-aarch64-ascend / SGLang_Perf-aarch64-ascend"
echo "  （SSH → ci_test@192.168.100.106 → daemon.sh Smoke <engine> ...）"
