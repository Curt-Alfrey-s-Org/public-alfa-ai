#!/usr/bin/env bash
# Poll GET /health until the brain API answers (or timeout).
#
# Usage:
#   bash deploy/cluster-members/_common/wait-brain-health.sh [TIMEOUT_SEC]
#
# Reads ALFA_AI_API_HOST_PORT from deploy/.env (default 8420).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ENV_FILE="${REPO_ROOT}/deploy/.env"
TIMEOUT_SEC="${1:-60}"
HOST_PORT="${ALFA_AI_API_HOST_PORT:-8420}"

if [[ -f "$ENV_FILE" ]]; then
  _p="$(grep -E '^ALFA_AI_API_HOST_PORT=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"')"
  [[ -n "$_p" ]] && HOST_PORT="$_p"
  unset _p
fi

exec bash "$(dirname "${BASH_SOURCE[0]}")/wait-http.sh" \
  "http://127.0.0.1:${HOST_PORT}/health" "$TIMEOUT_SEC"
