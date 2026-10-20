#!/usr/bin/env bash
# Phase H: deploy hub rpc-server shard :31353 (RTX 3050) for 27B pool.
#
# Stop Petals worker before run (hub single RTX 3050 — GPU mutual exclusion).
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/deploy-grev27-pool-shard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

sudo inference_STOP_MODE=shard HOST_LABEL=111 bash "$COMMON/inference-stop-local.sh"
sudo HOST_LABEL=111 bash "$COMMON/preflight-gpu-empty.sh"

sudo FORCE_HUB_RPC_LOAD="${FORCE_HUB_RPC_LOAD:-}" bash "$SCRIPT_DIR/deploy-llamacpp-rpc-shard.sh"
echo "deploy-grev27-pool-shard OK on hub (RTX 3050 :31353)"