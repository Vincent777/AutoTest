#!/usr/bin/env bash
# 本地依次跑 vLLM + SGLang（均走 daemon.sh）
#
# 用法:
#   ENGINES=vllm,sglang bash runners/run_weekly.sh
#   MODEL_LIST=DeepSeek-R1-Distill-Qwen-32B VERSION=main-xxx bash runners/run_weekly.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common/lib.sh
source "${ROOT}/runners/common/lib.sh"

ENGINES="${ENGINES:-vllm,sglang}"
MODEL_LIST="${MODEL_LIST:-DeepSeek-R1-Distill-Qwen-32B}"
BASE_JOB_ID="${JOB_ID:-${CI_JOB_ID:-weekly_$(date +%Y%m%d_%H%M%S)}}"
VERSION="${VERSION:-${CI_COMMIT_BRANCH:-local}-${CI_COMMIT_SHORT_SHA:-dev}}"
TEST_TYPE="${TEST_TYPE:-Smoke}"

log "weekly start engines=$ENGINES models=$MODEL_LIST version=$VERSION test_type=$TEST_TYPE"

IFS=',' read -r -a ENGINE_ARR <<< "$ENGINES"
for eng in "${ENGINE_ARR[@]}"; do
  eng="$(echo "$eng" | xargs | tr '[:upper:]' '[:lower:]')"
  [[ -n "$eng" ]] || continue
  case "$eng" in
    vllm)
      bash "${ROOT}/runners/run_vllm.sh" "$MODEL_LIST" "${BASE_JOB_ID}_vllm" "$VERSION" "$TEST_TYPE" \
        || log "WARN: vllm run failed"
      ;;
    sglang)
      bash "${ROOT}/runners/run_sglang.sh" "$MODEL_LIST" "${BASE_JOB_ID}_sglang" "$VERSION" "$TEST_TYPE" \
        || log "WARN: sglang run failed"
      ;;
    *)
      log "WARN: unknown engine $eng (use vllm|sglang)"
      ;;
  esac
done

log "weekly finished"
