#!/usr/bin/env bash
# 从共享目录收集本次 CI_JOB_ID 的 Performance Excel，拷到 workspace 供 artifacts 上传。
#
# 共享目录（Ascend 集群节点可见）:
#   /home/s_limingge/.npu_locks/artifacts/CI_ascend_test/${CI_JOB_ID}/performance
#
# 用法:
#   ENGINE_KEY=vllm CI_JOB_ID=12345 bash runners/fetch_ci_reports.sh
#
# 环境变量:
#   SHARED_PERF_ARTIFACTS  默认 /home/s_limingge/.npu_locks/artifacts/CI_ascend_test
#   OUT_DIR                默认 $LLM_PERF_DIR/ci_reports/$ENGINE_KEY
#   FETCH_TIMEOUT_SEC      等待报告出现的超时（默认 600）
#   FETCH_POLL_SEC         轮询间隔（默认 10）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLM_PERF_DIR="${LLM_PERF_DIR:-$ROOT}"
ENGINE_KEY="${ENGINE_KEY:?ENGINE_KEY required (vllm|sglang)}"
JOB_ID="${CI_JOB_ID:?CI_JOB_ID required}"
SHARED_ROOT="${SHARED_PERF_ARTIFACTS:-/home/s_limingge/.npu_locks/artifacts/CI_ascend_test}"
SRC_DIR="${SHARED_ROOT}/${JOB_ID}/performance"
OUT_DIR="${OUT_DIR:-${LLM_PERF_DIR}/ci_reports/${ENGINE_KEY}}"
TIMEOUT_SEC="${FETCH_TIMEOUT_SEC:-600}"
POLL_SEC="${FETCH_POLL_SEC:-10}"

mkdir -p "$OUT_DIR"

echo "[fetch_ci_reports] shared src = ${SRC_DIR}"
echo "[fetch_ci_reports] out dir    = ${OUT_DIR}"

deadline=$(( $(date +%s) + TIMEOUT_SEC ))
while true; do
  if [[ -d "$SRC_DIR" ]] && find "$SRC_DIR" -type f -name '*.xlsx' 2>/dev/null | grep -q .; then
    break
  fi
  if (( $(date +%s) >= deadline )); then
    echo "[fetch_ci_reports] ERROR: timeout waiting for *.xlsx under ${SRC_DIR}" >&2
    echo "[fetch_ci_reports] hint: ensure Runner mounts shared path into job container:" >&2
    echo "  /home/s_limingge/.npu_locks/artifacts:/home/s_limingge/.npu_locks/artifacts:ro" >&2
    ls -la "${SHARED_ROOT}/${JOB_ID}" 2>/dev/null || ls -la "$SHARED_ROOT" 2>/dev/null || true
    exit 1
  fi
  echo "[fetch_ci_reports] waiting for reports... ($(date '+%H:%M:%S'))"
  sleep "$POLL_SEC"
done

LOCAL_DIR="${OUT_DIR}/${JOB_ID}/performance"
mkdir -p "$LOCAL_DIR"
# 拷贝整个 performance 目录（xlsx / version.txt 等）
cp -a "${SRC_DIR}/." "$LOCAL_DIR/"

echo "[fetch_ci_reports] local files:"
find "$LOCAL_DIR" -type f | sort

if ! find "$LOCAL_DIR" -name '*.xlsx' | grep -q .; then
  echo "[fetch_ci_reports] ERROR: no .xlsx under ${LOCAL_DIR}" >&2
  exit 1
fi

echo "[fetch_ci_reports] done"
