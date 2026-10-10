#!/usr/bin/env bash
# Loop verify-inference-shards.sh until all TCP OK or max attempts exhausted.
#
# Usage:
#   bash deploy/cluster-members/_common/verify-inference-loop.sh
#   inference_LOOP_MAX=90 inference_LOOP_INTERVAL=10 bash .../verify-inference-loop.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX="${inference_LOOP_MAX:-60}"
INTERVAL="${inference_LOOP_INTERVAL:-10}"

attempt=1
while [[ "$attempt" -le "$MAX" ]]; do
  echo "== inference verify attempt ${attempt}/${MAX} =="
  if bash "$SCRIPT_DIR/verify-inference-shards.sh" "$@"; then
    echo "inference shards reachable (attempt ${attempt})"
    exit 0
  fi
  if [[ "$attempt" -ge "$MAX" ]]; then
    echo "ERROR: inference shards not reachable after ${MAX} attempts" >&2
    exit 1
  fi
  sleep "$INTERVAL"
  attempt=$((attempt + 1))
done
