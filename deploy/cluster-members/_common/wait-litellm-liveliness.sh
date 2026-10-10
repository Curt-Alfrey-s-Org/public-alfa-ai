#!/usr/bin/env bash
# Poll GET /health/liveliness until LiteLLM answers (or timeout).
# Use after: docker compose up -d --force-recreate alfa-ai-litellm
# Prerequisite: alfa-ai-redis and alfa-ai-postgres must be running (cache + Prisma).
#
# Usage (from repo root on hub):
#   bash deploy/cluster-members/_common/wait-litellm-liveliness.sh
#   bash deploy/cluster-members/_common/wait-litellm-liveliness.sh 180
#
# Env: reads ALFA_AI_LITELLM_HOST_PORT from deploy/.env when present (default 8413).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ENV_FILE="${REPO_ROOT}/deploy/.env"
TIMEOUT_SEC="${1:-120}"
INTERVAL_SEC="${2:-5}"
HOST_PORT="${ALFA_AI_LITELLM_HOST_PORT:-8413}"

if [[ -f "$ENV_FILE" ]]; then
  _p="$(grep -E '^ALFA_AI_LITELLM_HOST_PORT=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"')"
  [[ -n "$_p" ]] && HOST_PORT="$_p"
  unset _p
fi

URL="http://127.0.0.1:${HOST_PORT}/health/liveliness"
deadline=$((SECONDS + TIMEOUT_SEC))

echo "Polling ${URL} (timeout ${TIMEOUT_SEC}s, interval ${INTERVAL_SEC}s)..."

while (( SECONDS < deadline )); do
  if curl -fsS --max-time 5 "$URL" >/dev/null 2>&1; then
    echo "LiteLLM liveliness OK (${URL})"
    curl -fsS --max-time 5 "$URL" || true
    echo
    exit 0
  fi
  echo "  (not ready yet: connection refused or timeout; retry in ${INTERVAL_SEC}s)"
  sleep "$INTERVAL_SEC"
done

echo "WARN: LiteLLM did not respond within ${TIMEOUT_SEC}s (${URL})" >&2
echo "  Check: sudo docker logs --tail=100 alfa-ai-litellm" >&2
exit 1
