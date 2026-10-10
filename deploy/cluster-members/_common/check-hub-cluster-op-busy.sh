#!/usr/bin/env bash
# hub hub: detect long-running cluster operator scripts (stop / start-pool / start-brain).
# Used by orchestrator orchestrator preflight. Exit 0 = idle; exit 1 = busy (prints matching ps lines).
#
# Do NOT use pgrep on bare script names in a for-loop -- the probe command line contains those
# names and false-matches itself (20260705-142445-start).
set -euo pipefail

matches=$(
  {
    pgrep -af '/operator-cluster-111\.sh (stop|start-pool|start-brain)' 2>/dev/null || true
    pgrep -af '/scripts/stop\.sh' 2>/dev/null || true
    pgrep -af '/inference-stop-local\.sh' 2>/dev/null || true
  } | grep -vE '[/]pgrep|check-111-cluster-op-busy|for p in' | sort -u || true
)

if [[ -n "$matches" ]]; then
  echo "$matches"
  exit 1
fi
exit 0
