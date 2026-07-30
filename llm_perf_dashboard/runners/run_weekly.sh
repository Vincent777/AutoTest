#!/usr/bin/env bash
# 周更入口：解析最新 release tag，依次跑 vLLM / SGLang（仅 enabled 模型）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common/lib.sh
source "${ROOT}/runners/common/lib.sh"

ENGINES="${ENGINES:-vllm,sglang}"
DEVICES="${ASCEND_RT_VISIBLE_DEVICES:-0}"
DB="${ROOT}/storage/perf.db"

log "weekly run start engines=$ENGINES devices=$DEVICES"

IFS=',' read -r -a ENGINE_ARR <<< "$ENGINES"
for eng in "${ENGINE_ARR[@]}"; do
  eng="$(echo "$eng" | xargs)"
  [[ -n "$eng" ]] || continue
  case "$eng" in
    vllm)
      bash "${ROOT}/runners/run_vllm.sh" --devices "$DEVICES" || log "WARN: vllm run failed"
      ;;
    sglang)
      bash "${ROOT}/runners/run_sglang.sh" --devices "$DEVICES" || log "WARN: sglang run failed"
      ;;
    *)
      log "WARN: unknown engine $eng"
      ;;
  esac
done

log "weekly run finished db=$DB"
