#!/usr/bin/env bash
# Poll an HTTP URL until curl succeeds (2xx) or timeout.
#
# Usage:
#   bash deploy/cluster-members/_common/wait-http.sh URL [TIMEOUT_SEC] [INTERVAL_SEC]
#
# Examples:
#   bash .../wait-http.sh http://127.0.0.1:8420/health 60
#   bash .../wait-http.sh http://orchestrator/health 180 5

set -euo pipefail

URL="${1:?URL required (e.g. http://127.0.0.1:8420/health)}"
TIMEOUT_SEC="${2:-120}"
INTERVAL_SEC="${3:-5}"
CURL_MAX_TIME="${4:-5}"
deadline=$((SECONDS + TIMEOUT_SEC))

echo "Polling ${URL} (timeout ${TIMEOUT_SEC}s, interval ${INTERVAL_SEC}s)..."

while (( SECONDS < deadline )); do
  if curl -fsS --max-time "$CURL_MAX_TIME" "$URL" >/dev/null 2>&1; then
    echo "HTTP OK (${URL})"
    exit 0
  fi
  echo "  (not ready yet: connection refused, timeout, or non-2xx; retry in ${INTERVAL_SEC}s)"
  sleep "$INTERVAL_SEC"
done

echo "WARN: URL did not respond within ${TIMEOUT_SEC}s (${URL})" >&2
exit 1
