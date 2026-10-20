#!/usr/bin/env bash
# Local dev: FastAPI (orchestrator + /alfa-ai API + SPA when frontend/dist exists)
# plus Vite dev server with proxy to the API. Open http://127.0.0.1:5173/alfa-ai/
#
# Prerequisites: pip install -r requirements.txt ; cd frontend && npm ci
# For login/admin routes set DATABASE_URL and ALFA_AI_JWT_SECRET in deploy/.env.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

API_PORT="${API_PORT:-8412}"
VITE_PORT="${VITE_PORT:-5173}"
export ALFA_AI_WORKSPACE_ROOT="${ALFA_AI_WORKSPACE_ROOT:-$ROOT/.alfa_workspace_dev}"
mkdir -p "$ALFA_AI_WORKSPACE_ROOT"

if ! command -v uvicorn >/dev/null 2>&1; then
  echo "uvicorn not found. Run: pip install -r requirements.txt"
  exit 1
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "npm not found. Install Node.js for the Vite frontend."
  exit 1
fi

cleanup() {
  kill "${UVICORN_PID:-0}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Starting API on http://127.0.0.1:${API_PORT} (reload) ..."
uvicorn src.api.app:app --reload --host 127.0.0.1 --port "${API_PORT}" &
UVICORN_PID=$!

cd "${ROOT}/frontend"
echo "Starting Vite on http://127.0.0.1:${VITE_PORT} (proxies /alfa-ai/api -> :${API_PORT}) ..."
npm run dev -- --host 127.0.0.1 --port "${VITE_PORT}"
STATUS=$?
cleanup
exit "${STATUS}"
