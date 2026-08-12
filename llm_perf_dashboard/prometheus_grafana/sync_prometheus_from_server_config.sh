#!/usr/bin/env bash
# Generate prometheus.yaml from server_config.txt and reload Prometheus.
#
# Usage:
#   bash sync_prometheus_from_server_config.sh --job-id <JOB_ID>
#   PD_JOB_ID=... bash sync_prometheus_from_server_config.sh
#
# Env / flags:
#   --job-id / PD_JOB_ID              required (or --job-id)
#   --server-config / PD_SERVER_CONFIG default: /home/s_limingge/.npu_locks/server_config.txt
#   --output / PROMETHEUS_OUTPUT      default: <this_dir>/vllm/prometheus.yaml
#   --engine / PD_ENGINE              optional default engine= for lines missing engine=
#   --wait-timeout SEC                wait until generate succeeds (topology complete), default 180
#   --reload-url / PROMETHEUS_RELOAD_URL  default: http://127.0.0.1:9090/-/reload
#   PROMETHEUS_RELOAD_STRICT=1        if set, reload failure exits non-zero
#
# Note: scrape IPs are taken from server_config (often 10.0.0.x). Prometheus must reach them.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GEN_PY="${SCRIPT_DIR}/generate_prometheus_yaml.py"

SERVER_CONFIG="${PD_SERVER_CONFIG:-/home/s_limingge/.npu_locks/server_config.txt}"
JOB_ID="${PD_JOB_ID:-}"
OUTPUT="${PROMETHEUS_OUTPUT:-${SCRIPT_DIR}/vllm/prometheus.yaml}"
ENGINE="${PD_ENGINE:-}"
WAIT_TIMEOUT="${PD_SYNC_WAIT_TIMEOUT:-180}"
RELOAD_URL="${PROMETHEUS_RELOAD_URL:-http://127.0.0.1:9090/-/reload}"
PRINT_SUMMARY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-id)
      JOB_ID="$2"
      shift 2
      ;;
    --server-config)
      SERVER_CONFIG="$2"
      shift 2
      ;;
    --output|-o)
      OUTPUT="$2"
      shift 2
      ;;
    --engine)
      ENGINE="$2"
      shift 2
      ;;
    --wait-timeout)
      WAIT_TIMEOUT="$2"
      shift 2
      ;;
    --reload-url)
      RELOAD_URL="$2"
      shift 2
      ;;
    --no-summary)
      PRINT_SUMMARY=0
      shift
      ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${JOB_ID}" ]]; then
  echo "ERROR: --job-id or PD_JOB_ID is required" >&2
  exit 2
fi

if [[ ! -f "${GEN_PY}" ]]; then
  echo "ERROR: generator not found: ${GEN_PY}" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found" >&2
  exit 1
fi

gen_args=(
  --from-server-config "${SERVER_CONFIG}"
  --job-id "${JOB_ID}"
  -o "${OUTPUT}"
)
if [[ -n "${ENGINE}" ]]; then
  gen_args+=(--engine "${ENGINE}")
fi
if [[ "${PRINT_SUMMARY}" -eq 1 ]]; then
  gen_args+=(--print-summary)
fi

echo "Sync Prometheus scrape config from ${SERVER_CONFIG} (job_id=${JOB_ID})"
echo "  output=${OUTPUT}"
echo "  wait_timeout=${WAIT_TIMEOUT}s"

start_ts=$(date +%s)
ok=0
err_file=$(mktemp)
trap 'rm -f "${err_file}"' EXIT
while true; do
  if python3 "${GEN_PY}" "${gen_args[@]}" 2>"${err_file}"; then
    cat "${err_file}" >&2 || true
    ok=1
    break
  fi
  cat "${err_file}" >&2 || true
  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ "${elapsed}" -ge "${WAIT_TIMEOUT}" ]]; then
    echo "WARN: generate still failing after ${WAIT_TIMEOUT}s (topology incomplete?)." >&2
    echo "WARN: skip prometheus.yaml update; continuing without blocking the test." >&2
    exit 0
  fi
  echo "Waiting for all PD nodes in server_config... (${elapsed}/${WAIT_TIMEOUT}s)"
  sleep 5
done

if [[ "${ok}" -ne 1 ]]; then
  echo "ERROR: unexpected generate failure" >&2
  exit 1
fi

echo "Reloading Prometheus: ${RELOAD_URL}"
if curl -fsS -X POST "${RELOAD_URL}"; then
  echo "Prometheus reload OK"
  exit 0
fi

echo "WARN: Prometheus reload failed (url=${RELOAD_URL}). Config file was written: ${OUTPUT}" >&2
if [[ "${PROMETHEUS_RELOAD_STRICT:-0}" == "1" ]]; then
  exit 1
fi
exit 0
