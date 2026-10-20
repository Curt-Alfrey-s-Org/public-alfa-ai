#!/usr/bin/env bash
# Phase H: deploy inference :31356 shard for 27B pool. CPU coordinator :31360 on same host.
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/switch-pool-27b.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

HOST_LABEL=148 bash "$COMMON/inference-stop-local.sh"
HOST_LABEL=148 bash "$COMMON/preflight-gpu-empty.sh"

echo "== switch-pool-27b: inference rpc-server shard :31356 =="
bash "$SCRIPT_DIR/deploy-grev27-pool-shard.sh"

echo "== switch-pool-27b (inference shard) complete =="
echo "Ensure orchestrator and hub shards are up, then on hub:"
echo "  sudo bash deploy/cluster-members/hub/switch-pool-27b.sh"
echo "Then deploy coordinator on inference:"
echo "  bash deploy/cluster-members/inference-coordinator/deploy-grev27-pool-coordinator.sh"
echo "LiteLLM: LLAMACPP_CODE27_URL=http://orchestrator/v1"
