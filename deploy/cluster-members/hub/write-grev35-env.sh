#!/usr/bin/env bash
# Write G-rev35 .env.rpc from pool35-shards.env (declarative shard list).
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/write-grev35-env.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

export ALFA_REPO_DIR="$REPO_DIR"
export MODELS_DIR="${MODELS_DIR:-/mnt/hub/alfa-ai/llama-cpp/models}"
export SLOT_CACHE_DIR="${SLOT_CACHE_DIR:-$(bash "$COMMON/default-slot-cache-dir-111.sh" "$REPO_DIR")}"
export COORDINATOR_LOOPBACK_LOCAL_SHARD=127.0.0.1:31353

bash "$COMMON/write-grev35-pool-env-from-shards.sh"
