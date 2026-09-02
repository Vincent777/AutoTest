#!/usr/bin/env bash
# ModelScope 模型断点续传下载（HTTP + curl，兼容 Python 3.7）
#
# 用法:
#   ./ms_resume_download.sh start LLM-Research/Meta-Llama-3.1-70B-Instruct ./Meta-Llama-3.1-70B-Instruct
#   ./ms_resume_download.sh status
#   ./ms_resume_download.sh log
#   ./ms_resume_download.sh stop
#
# 说明:
#   - 不走 git clone（避免卡在 Cloning into... 几小时）
#   - 用 ModelScope HTTP 接口 + curl -C - 断点续传
#   - SSH 断开不影响（nohup 后台跑）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${PWD}"
PID_FILE="${WORK_DIR}/.ms_download.pid"
LOG_FILE="${WORK_DIR}/ms_download.log"
WORKER="${SCRIPT_DIR}/ms_resume_download_worker.sh"

cmd="${1:-}"
shift || true

start() {
  local model="${1:-}"
  local local_dir="${2:-}"
  local token="${3:-${MODELSCOPE_API_TOKEN:-${MS_TOKEN:-}}}"

  if [[ -z "${model}" || -z "${local_dir}" ]]; then
    echo "用法: $0 start <model_id> <local_dir> [modelscope_token]"
    echo "示例: $0 start LLM-Research/Meta-Llama-3.1-70B-Instruct ./Meta-Llama-3.1-70B-Instruct"
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "需要 curl"
    exit 1
  fi

  if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "已有下载在跑, pid=$(cat "${PID_FILE}")"
    echo "查看日志: $0 log"
    exit 0
  fi

  # 清掉卡住的空 git 目录（只有 .git 或几乎空），避免干扰 HTTP 下载
  if [[ -d "${local_dir}/.git" ]]; then
    echo "检测到旧的 git 半成品目录，将改名为 ${local_dir}.git_stuck.bak"
    mv "${local_dir}" "${local_dir}.git_stuck.bak" || true
  fi

  nohup bash "${WORKER}" \
    --model "${model}" \
    --local-dir "${local_dir}" \
    --token "${token}" \
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
      # 杀掉子进程（curl/git）和主进程
      pkill -P "${pid}" 2>/dev/null || true
      kill "${pid}" 2>/dev/null || true
      sleep 1
      kill -9 "${pid}" 2>/dev/null || true
      pkill -f "git clone.*Meta-Llama-3.1-70B-Instruct" 2>/dev/null || true
      echo "已停止 pid=${pid}"
    else
      echo "进程已不存在"
    fi
    rm -f "${PID_FILE}"
  else
    echo "没有 pid 文件，尝试清理卡住的 git clone..."
    pkill -f "git clone.*Meta-Llama-3.1-70B-Instruct" 2>/dev/null || true
  fi
}

case "${cmd}" in
  start) start "$@" ;;
  status) status ;;
  log) show_log ;;
  stop) stop ;;
  *)
    echo "用法:"
    echo "  $0 start <model_id> <local_dir> [token]"
    echo "  $0 status"
    echo "  $0 log"
    echo "  $0 stop"
    echo ""
    echo "示例:"
    echo "  $0 start LLM-Research/Meta-Llama-3.1-70B-Instruct ./Meta-Llama-3.1-70B-Instruct"
    exit 1
    ;;
esac
