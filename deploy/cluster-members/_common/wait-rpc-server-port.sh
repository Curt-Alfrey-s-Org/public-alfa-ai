#!/usr/bin/env bash
# Wait for rpc-server TCP accept on RPC_PORT.
#
# Usage:
#   bash wait-rpc-server-port.sh [PORT] [HOST] [CONTAINER] [TIMEOUT_SEC] [INTERVAL_SEC]
set -euo pipefail

PORT="${1:-31350}"
HOST="${2:-127.0.0.1}"
CONTAINER="${3:-llamacpp-rpc-server}"
TIMEOUT_SEC="${4:-300}"
INTERVAL_SEC="${5:-5}"
deadline=$((SECONDS + TIMEOUT_SEC))

echo "Polling rpc-server ${HOST}:${PORT} (timeout ${TIMEOUT_SEC}s)..."

while (( SECONDS < deadline )); do
  if nc -z -w 3 "$HOST" "$PORT" 2>/dev/null; then
    echo "rpc-server ready on ${HOST}:${PORT}"
    exit 0
  fi
  echo "  (not accepting yet; retry in ${INTERVAL_SEC}s)"
  sleep "$INTERVAL_SEC"
done

echo "ERROR: rpc-server :${PORT} not ready after ${TIMEOUT_SEC}s (check: docker logs ${CONTAINER})" >&2
exit 1
