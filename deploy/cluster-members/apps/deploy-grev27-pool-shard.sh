#!/usr/bin/env bash
# Phase H: deploy apps rpc-server shard :31354 for 27B pool (GTX 1660S).
#
# Usage (on apps):
#   bash deploy/cluster-members/apps/deploy-grev27-pool-shard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/home/operator/alfa-ai}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
COMMON="$REPO_DIR/deploy/cluster-members/_common"
ENV_RPC="$LLC/.env.rpc"

HOST_LABEL=105 bash "$COMMON/inference-stop-local.sh"
HOST_LABEL=105 bash "$COMMON/preflight-gpu-empty.sh"

mkdir -p "$(dirname "$ENV_RPC")"
cat >"$ENV_RPC" <<'EOF'
# Phase H: apps rpc-server shard for 27B pool (:31354)
CUDA_VISIBLE_DEVICES=0
RPC_PORT=31354
EOF

bash "$SCRIPT_DIR/deploy-llamacpp-rpc-shard.sh"
echo "deploy-grev27-pool-shard OK on apps"
