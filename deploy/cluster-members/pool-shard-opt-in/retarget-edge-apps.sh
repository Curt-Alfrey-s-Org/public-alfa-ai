#!/usr/bin/env bash
# Track A ONLY — retarget apps edge upstream to VM100 brain.
#
# Track B (selected): edge stays on hub:8420 — do not run this script.
#
# Usage (Track A):
#   ALFA_BRAIN_HOST=orchestrator bash deploy/cluster-members/pool-shard-opt-in/retarget-edge-105.sh
set -euo pipefail

echo "ERROR: Track B selected — edge upstream stays http://hub" >&2
echo "This script is for Track A (brain on VM100) only." >&2
exit 1