#!/usr/bin/env bash
# 公共工具：加载配置路径、等待 OpenAI 服务就绪、清理容器
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export LLM_PERF_ROOT="${LLM_PERF_ROOT:-$ROOT}"

log() { echo "[$(date '+%F %T')] $*"; }

wait_openai_ready() {
  local host="$1" port="$2" timeout_sec="${3:-1800}" interval="${4:-10}"
  local deadline=$(( $(date +%s) + timeout_sec ))
  while (( $(date +%s) < deadline )); do
    if curl -fsS "http://${host}:${port}/v1/models" >/dev/null 2>&1; then
      log "service ready on ${host}:${port}"
      return 0
    fi
    sleep "$interval"
  done
  log "ERROR: service not ready within ${timeout_sec}s on ${host}:${port}"
  return 1
}

stop_container() {
  local name="$1"
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    docker stop "$name" >/dev/null 2>&1 || true
    docker rm "$name" >/dev/null 2>&1 || true
  fi
}

get_free_port() {
  local start="${1:-20000}" end="${2:-20999}"
  local port
  for port in $(seq "$start" "$end"); do
    if ! ss -ltn | awk '{print $4}' | grep -E ":${port}$" >/dev/null 2>&1; then
      echo "$port"
      return 0
    fi
  done
  return 1
}
