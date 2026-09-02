#!/usr/bin/env bash
# ModelScope HTTP 断点续传下载 worker（不走 git，避免卡在 Cloning）
# 依赖: curl, python3(仅标准库解析 JSON)
set -uo pipefail

MODEL=""
LOCAL_DIR=""
TOKEN=""
RETRY_WAIT=30
MAX_RETRIES=0
REVISION="master"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --local-dir) LOCAL_DIR="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --retry-wait) RETRY_WAIT="$2"; shift 2 ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${MODEL}" || -z "${LOCAL_DIR}" ]]; then
  echo "missing --model / --local-dir"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "需要 curl"
  exit 1
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

LOCAL_DIR="$(mkdir -p "${LOCAL_DIR}" && cd "${LOCAL_DIR}" && pwd)"
LIST_JSON="${LOCAL_DIR}/.ms_file_list.json"
FILE_LIST="${LOCAL_DIR}/.ms_file_list.txt"
AUTH_HEADER=()
if [[ -n "${TOKEN}" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
fi

# 拉取文件清单
fetch_file_list() {
  local api_url="https://www.modelscope.cn/api/v1/models/${MODEL}/repo/files?Revision=${REVISION}&Recursive=True"
  log "fetch file list: ${api_url}"
  curl -fsSL --connect-timeout 30 --max-time 300 \
    "${AUTH_HEADER[@]}" \
    "${api_url}" -o "${LIST_JSON}"
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    return ${rc}
  fi

  python3 - "${LIST_JSON}" "${FILE_LIST}" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r") as f:
    data = json.load(f)
files = []
# 兼容多种返回结构
candidates = []
if isinstance(data, dict):
    if isinstance(data.get("Data"), dict) and "Files" in data["Data"]:
        candidates = data["Data"]["Files"]
    elif isinstance(data.get("Data"), list):
        candidates = data["Data"]
    elif "Files" in data:
        candidates = data["Files"]
elif isinstance(data, list):
    candidates = data

for item in candidates:
    if not isinstance(item, dict):
        continue
    # Type: blob/tree ; 有的字段叫 type
    typ = str(item.get("Type") or item.get("type") or "").lower()
    path = item.get("Path") or item.get("path") or item.get("Name") or item.get("name")
    if not path:
        continue
    if typ in ("tree", "dir", "directory"):
        continue
    size = item.get("Size") or item.get("size") or 0
    files.append("{}\t{}".format(path, size))

if not files:
    sys.stderr.write("ERROR: empty file list, raw keys=%s\n" % (list(data.keys()) if isinstance(data, dict) else type(data)))
    sys.exit(3)

with open(dst, "w") as f:
    f.write("\n".join(files) + "\n")
print("listed %d files" % len(files))
PY
}

# 下载单个文件（curl 断点续传）
download_one() {
  local rel_path="$1"
  local expect_size="$2"
  local out_path="${LOCAL_DIR}/${rel_path}"
  local url="https://www.modelscope.cn/models/${MODEL}/resolve/${REVISION}/${rel_path}"

  mkdir -p "$(dirname "${out_path}")"

  if [[ -n "${expect_size}" && "${expect_size}" -gt 0 && -f "${out_path}" ]]; then
    local cur
    cur="$(wc -c < "${out_path}" | tr -d ' ')"
    if [[ "${cur}" == "${expect_size}" ]]; then
      log "skip (complete): ${rel_path} (${cur} bytes)"
      return 0
    fi
    log "resume: ${rel_path} (${cur}/${expect_size})"
  else
    log "download: ${rel_path}"
  fi

  # -C - 断点续传；--fail 对 4xx/5xx 返回非0；大文件不设 max-time
  curl -fL --connect-timeout 30 --retry 5 --retry-delay 5 \
    -C - \
    "${AUTH_HEADER[@]}" \
    -o "${out_path}" \
    "${url}"
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    log "curl failed rc=${rc} file=${rel_path}"
    return ${rc}
  fi

  if [[ -n "${expect_size}" && "${expect_size}" -gt 0 ]]; then
    local cur
    cur="$(wc -c < "${out_path}" | tr -d ' ')"
    if [[ "${cur}" != "${expect_size}" ]]; then
      log "size mismatch: ${rel_path} got=${cur} expect=${expect_size}"
      return 4
    fi
  fi
  return 0
}

download_all() {
  fetch_file_list || return $?
  local total done=0 fail=0
  total="$(wc -l < "${FILE_LIST}" | tr -d ' ')"
  log "total files: ${total}"

  while IFS=$'\t' read -r path size; do
    [[ -z "${path}" ]] && continue
    done=$((done + 1))
    log "progress ${done}/${total}"
    if ! download_one "${path}" "${size}"; then
      fail=$((fail + 1))
      log "file failed: ${path}"
      return 5
    fi
  done < "${FILE_LIST}"

  log "all files downloaded, fail=${fail}"
  return 0
}

attempt=0
while true; do
  attempt=$((attempt + 1))
  log "attempt #${attempt} start: model=${MODEL} local_dir=${LOCAL_DIR} revision=${REVISION}"

  set +e
  download_all
  rc=$?
  set -e

  if [[ ${rc} -eq 0 ]]; then
    log "SUCCESS: downloaded to ${LOCAL_DIR}"
    exit 0
  fi

  log "FAILED: exit_code=${rc}"
  if [[ "${MAX_RETRIES}" -gt 0 && "${attempt}" -ge "${MAX_RETRIES}" ]]; then
    log "reached max retries (${MAX_RETRIES}), exit"
    exit 1
  fi
  log "wait ${RETRY_WAIT}s then retry (resume from existing files)..."
  sleep "${RETRY_WAIT}"
done
