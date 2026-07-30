#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOST="${DASHBOARD_HOST:-0.0.0.0}"
PORT="${DASHBOARD_PORT:-8088}"

python3 -m pip install --user -q -r requirements.txt 2>/dev/null \
  || python3 -m pip install -q -r requirements.txt

echo "Dashboard: http://${HOST}:${PORT}/"
exec python3 -m uvicorn api.main:app --host "$HOST" --port "$PORT" --app-dir "$ROOT"
