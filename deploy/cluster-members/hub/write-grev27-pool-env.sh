#!/usr/bin/env bash
# Write .env.rpc for 27B RPC pool CPU coordinator on hub (:31360).
# Shard list: inference_SHARDS_FILE, else inference-shards.active.env, else inference-shards.env
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/write-grev27-pool-env.sh
#   sudo inference_SHARDS_FILE=.../inference-shards.active.env bash .../write-grev27-pool-env.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"
LLC="$REPO_DIR/deploy/llamacpp-rpc"

export ALFA_REPO_DIR="$REPO_DIR"
MODEL_FILE="${inference_MODEL_FILE:-Qwen3.8-27B-Q8_0.gguf}"
# Prefer SSD/NVMe hot copy of GGUF (spinning HDD = archive only).
if [[ -z "${MODELS_DIR:-}" ]]; then
  MODELS_DIR=""
  for cand in \
    "/mnt/nvme/Alfa-AI/llama-cpp/models" \
    "/mnt/ssd/Alfa-AI/llama-cpp/models" \
    "/mnt/hub/alfa-ai/llama-cpp/models"
  do
    if [[ -f "$cand/$MODEL_FILE" ]]; then
      MODELS_DIR="$cand"
      break
    fi
  done
  MODELS_DIR="${MODELS_DIR:-/mnt/hub/alfa-ai/llama-cpp/models}"
fi
export MODELS_DIR
if [[ ! -f "$MODELS_DIR/$MODEL_FILE" ]]; then
  echo "ERROR: missing GGUF $MODELS_DIR/$MODEL_FILE" >&2
  exit 1
fi
bash "$COMMON/ensure-gguf-posix-other-read.sh" "$MODELS_DIR" "$MODEL_FILE"
export inference_MODEL_FILE="$MODEL_FILE"
export SLOT_CACHE_DIR="${SLOT_CACHE_DIR:-$(bash "$COMMON/default-slot-cache-dir-111.sh" "$REPO_DIR")}"
# Coordinator on same host as :31353 shard -- loopback avoids hairpin + RPC wedge.
export COORDINATOR_LOOPBACK_LOCAL_SHARD=127.0.0.1:31353
echo "== MODELS_DIR=$MODELS_DIR (hot SSD/NVMe preferred over HDD) =="

if [[ -z "${inference_SHARDS_FILE:-}" ]]; then
  if [[ -f "$LLC/inference-shards.active.env" ]]; then
    export inference_SHARDS_FILE="$LLC/inference-shards.active.env"
  else
    export inference_SHARDS_FILE="$LLC/inference-shards.env"
  fi
fi
echo "== write-grev27-pool-env: shards from $inference_SHARDS_FILE =="

bash "$COMMON/write-grev27-pool-env-from-shards.sh"