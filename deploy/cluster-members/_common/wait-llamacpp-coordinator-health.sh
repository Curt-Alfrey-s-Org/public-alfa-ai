#!/usr/bin/env bash
# Poll llama-server /health with load-tolerant per-request timeout (#20684 on b8552).
#
# Usage:
#   bash wait-llamacpp-coordinator-health.sh URL [TOTAL_TIMEOUT_SEC] [INTERVAL_SEC]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${1:?URL required (e.g. http://127.0.0.1:31360/health)}"
TOTAL="${2:-900}"
INTERVAL="${3:-10}"
exec bash "$SCRIPT_DIR/wait-http.sh" "$URL" "$TOTAL" "$INTERVAL" 15
