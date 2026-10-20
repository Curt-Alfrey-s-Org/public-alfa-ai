#!/usr/bin/env bash
# Write .env.rpc for exclusive Qwen3-Coder-Next Q5_K_M on hub (:31360).
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/write-grev80-pool-env.sh
#
# Docs: docs/GREV80_80B_OPERATOR.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"
LLC="$REPO_DIR/deploy/llamacpp-rpc"

export ALFA_REPO_DIR="$REPO_DIR"
MODEL_FILE="${POOL80_MODEL_FILE:-Qwen3-Coder-Next-Q5_K_M/Qwen3-Coder-Next-Q5_K_M-00001-of-00004.gguf}"
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
export inference_MODEL_FILE="$MODEL_FILE"
export MODEL_ALIAS="${MODEL_ALIAS:-qwen3-coder-next-80b-a3b}"
export PARALLEL="${PARALLEL:-1}"
# Shared exclusive-pool policy with Pool72 (operator YOLO 2026-08-10).
export CTX_SIZE="${CTX_SIZE:-86016}"
export LOAD_TIMEOUT="${LOAD_TIMEOUT:-1800}"
export SLOT_CACHE_DIR="${SLOT_CACHE_DIR:-$(bash "$COMMON/default-slot-cache-dir-111.sh" "$REPO_DIR")}"
export COORDINATOR_LOOPBACK_LOCAL_SHARD=127.0.0.1:31353

# Native 262144 -- no YaRN at CTX 86016.
unset ROPE_SCALING_TYPE ROPE_SCALE YARN_ORIG_CTX || true

echo "== GREV80 MODELS_DIR=$MODELS_DIR MODEL_FILE=$MODEL_FILE PARALLEL=$PARALLEL CTX_SIZE=$CTX_SIZE =="

if [[ ! -f "$MODELS_DIR/$MODEL_FILE" ]]; then
  echo "ERROR: missing GGUF $MODELS_DIR/$MODEL_FILE - seed with: sudo bash scripts/hub_hub_models.sh pull gguf" >&2
  exit 1
fi
bash "$COMMON/ensure-gguf-posix-other-read.sh" "$MODELS_DIR" "$MODEL_FILE"

if [[ -z "${inference_SHARDS_FILE:-}" ]]; then
  if [[ -f "$LLC/inference-shards.active.env" ]]; then
    export inference_SHARDS_FILE="$LLC/inference-shards.active.env"
  else
    export inference_SHARDS_FILE="$LLC/inference-shards.env"
  fi
fi
echo "== write-grev80-pool-env: shards from $inference_SHARDS_FILE =="

bash "$COMMON/write-grev27-pool-env-from-shards.sh"
