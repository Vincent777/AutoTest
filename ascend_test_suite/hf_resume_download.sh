#!/usr/bin/env bash
# 后台启动 HF 断点续传下载，SSH 断开不影响。
#
# 用法:
#   ./hf_resume_download.sh start meta-llama/Meta-Llama-3.1-70B-Instruct ./Meta-Llama-3.1-70B-Instruct [HF_TOKEN]
#   ./hf_resume_download.sh status
#   ./hf_resume_download.sh log
#   ./hf_resume_download.sh stop

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY_SCRIPT="${SCRIPT_DIR}/hf_resume_download.py"
WORK_DIR="${PWD}"
PID_FILE="${WORK_DIR}/.hf_download.pid"
LOG_FILE="${WORK_DIR}/hf_download.log"

# 默认走国内镜像，可被外部环境覆盖
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"

cmd="${1:-}"
shift || true

start() {
  local repo="${1:-}"
  local local_dir="${2:-}"
  local token="${3:-${HF_TOKEN:-}}"

  if [[ -z "${repo}" || -z "${local_dir}" ]]; then
    echo "用法: $0 start <repo_id> <local_dir> [token]"
    exit 1
  fi

  if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "已有下载在跑, pid=$(cat "${PID_FILE}")"
    echo "查看日志: $0 log"
    exit 0
  fi

  local token_arg=()
  if [[ -n "${token}" ]]; then
    token_arg=(--token "${token}")
  fi

  nohup python3 "${PY_SCRIPT}" \
    --repo "${repo}" \
    --local-dir "${local_dir}" \
    "${token_arg[@]}" \
    --max-retries 0 \
    --retry-wait 30 \
    > "${LOG_FILE}" 2>&1 &

  echo $! > "${PID_FILE}"
  echo "已后台启动, pid=$(cat "${PID_FILE}")"
  echo "日志: ${LOG_FILE}"
  echo "查看: $0 log"
  echo "状态: $0 status"
}

status() {
  if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "RUNNING pid=$(cat "${PID_FILE}")"
    echo "log: ${LOG_FILE}"
    tail -n 5 "${LOG_FILE}" 2>/dev/null || true
  else
    echo "NOT RUNNING"
    if [[ -f "${LOG_FILE}" ]]; then
      echo "最近日志:"
      tail -n 20 "${LOG_FILE}" || true
    fi
  fi
}

show_log() {
  if [[ ! -f "${LOG_FILE}" ]]; then
    echo "日志不存在: ${LOG_FILE}"
    exit 1
  fi
  tail -f "${LOG_FILE}"
}

stop() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" || true
      echo "已发送停止信号给 pid=${pid}"
    else
      echo "进程已不存在"
    fi
    rm -f "${PID_FILE}"
  else
    echo "没有 pid 文件"
  fi
}

case "${cmd}" in
  start) start "$@" ;;
  status) status ;;
  log) show_log ;;
  stop) stop ;;
  *)
    echo "用法:"
    echo "  $0 start <repo_id> <local_dir> [token]"
    echo "  $0 status"
    echo "  $0 log"
    echo "  $0 stop"
    exit 1
    ;;
esac
