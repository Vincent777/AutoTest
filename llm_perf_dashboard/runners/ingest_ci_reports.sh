#!/usr/bin/env bash
# 从共享目录读取本次 CI 的 Performance Excel，写入正式长期 SQLite。
#
# 用法:
#   bash runners/ingest_ci_reports.sh \
#     --shared-root /home/s_limingge/.npu_locks/artifacts/CI_ascend_test \
#     --job-ids 123,456 \
#     --db /home/s_limingge/ci_autotest/llm_perf_dashboard/storage/perf.db
#
# 兼容旧用法:
#   bash runners/ingest_ci_reports.sh /path/to/ci_reports
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_ROOT=""
JOB_IDS=""
REPORT_ROOT=""
OUT_DIR="${ROOT}/results"
DB="${ROOT}/storage/perf.db"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shared-root) SHARED_ROOT="$2"; shift 2 ;;
    --job-ids) JOB_IDS="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
    *)
      # positional: legacy report root
      REPORT_ROOT="$1"
      shift
      ;;
  esac
done

mkdir -p "$OUT_DIR" "$(dirname "$DB")"

EXCELS=()
if [[ -n "$SHARED_ROOT" && -n "$JOB_IDS" ]]; then
  IFS=',' read -r -a ID_ARR <<< "$JOB_IDS"
  for jid in "${ID_ARR[@]}"; do
    jid="$(echo "$jid" | xargs)"
    [[ -n "$jid" ]] || continue
    src="${SHARED_ROOT}/${jid}/performance"
    echo "[ingest_ci_reports] scan ${src}"
    if [[ ! -d "$src" ]]; then
      echo "[ingest_ci_reports] ERROR: missing ${src}" >&2
      exit 1
    fi
    while IFS= read -r f; do
      EXCELS+=("$f")
    done < <(find "$src" -type f -name '*.xlsx' | sort)
  done
elif [[ -n "$REPORT_ROOT" ]]; then
  echo "[ingest_ci_reports] scan ${REPORT_ROOT}"
  while IFS= read -r f; do
    EXCELS+=("$f")
  done < <(find "$REPORT_ROOT" -type f -name '*.xlsx' | sort)
else
  echo "[ingest_ci_reports] ERROR: provide --shared-root + --job-ids, or a report root path" >&2
  exit 1
fi

if [[ ${#EXCELS[@]} -eq 0 ]]; then
  echo "[ingest_ci_reports] ERROR: no .xlsx found" >&2
  exit 1
fi

echo "[ingest_ci_reports] found ${#EXCELS[@]} excel file(s):"
printf '  %s\n' "${EXCELS[@]}"
echo "[ingest_ci_reports] db=${DB}"

python3 "${ROOT}/collector/excel_to_json.py" \
  "${EXCELS[@]}" \
  --out-dir "$OUT_DIR" \
  --merged "${OUT_DIR}/ci_ingest_$(date +%Y%m%d_%H%M%S).json" \
  --db "$DB" \
  --ingest

python3 - <<PY
import sqlite3
c = sqlite3.connect("${DB}")
print("runs by engine:", c.execute("select engine, count(*) from runs group by engine").fetchall())
print("total:", c.execute("select count(*) from runs").fetchone()[0])
PY
