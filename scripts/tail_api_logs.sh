#!/usr/bin/env bash
# Follow ALFa AI API container logs (rankings-bot scripts/tail_api_logs.sh pattern).
#
# Env:
#   CONTAINER_NAME (default alfa-ai-api)
#   TAIL_LINES (default 200)

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-alfa-ai-api}"
TAIL_LINES="${TAIL_LINES:-200}"

DOCKER=(docker)
if ! docker info &>/dev/null; then
  DOCKER=(sudo docker)
fi

if ! "${DOCKER[@]}" info &>/dev/null; then
  echo "Docker is not available." >&2
  exit 2
fi

exec "${DOCKER[@]}" logs --timestamps --tail "$TAIL_LINES" -f "$CONTAINER_NAME"
