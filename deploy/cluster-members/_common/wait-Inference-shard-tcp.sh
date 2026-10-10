#!/usr/bin/env bash
# Poll host:port until nc accepts TCP (from this host's network path).
#
# Usage:
#   bash wait-inference-shard-tcp.sh HOST PORT [TIMEOUT_SEC] [INTERVAL_SEC]
#
# Examples:
#   bash .../wait-inference-shard-tcp.sh hub 31353 120
#   bash .../wait-inference-shard-tcp.sh 127.0.0.1 31350 180 5
set -euo pipefail

HOST="${1:?HOST required}"
PORT="${2:?PORT required}"
TIMEOUT_SEC="${3:-120}"
INTERVAL_SEC="${4:-2}"
deadline=$((SECONDS + TIMEOUT_SEC))

echo "Polling TCP ${HOST}:${PORT} (timeout ${TIMEOUT_SEC}s, interval ${INTERVAL_SEC}s)..."

while (( SECONDS < deadline )); do
  if nc -z -w 3 "$HOST" "$PORT" 2>/dev/null; then
    echo "TCP OK (${HOST}:${PORT})"
    exit 0
  fi
  echo "  (not accepting yet; retry in ${INTERVAL_SEC}s)"
  sleep "$INTERVAL_SEC"
done

echo "WARN: ${HOST}:${PORT} not accepting TCP within ${TIMEOUT_SEC}s" >&2
exit 1
