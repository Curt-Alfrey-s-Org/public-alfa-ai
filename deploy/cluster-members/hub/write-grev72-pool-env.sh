#!/usr/bin/env bash
# Write .env.rpc for exclusive Qwen2.5-72B-Instruct Q5_K_M on hub (:31360).
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/write-grev72-pool-env.sh
#   sudo inference_SHARDS_FILE=.../inference-shards.active.env bash .../write-grev72-pool-env.sh
#
# Docs: docs/GREV72_72B_OPERATOR.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"
LLC="$REPO_DIR/deploy/llamacpp-rpc"

export ALFA_REPO_DIR="$REPO_DIR"
# Operator policy 2026-08-10: Q5_K_M + CTX 86016 (shared with Pool80).
MODEL_FILE="${POOL72_MODEL_FILE:-qwen2.5-72b-instruct-q5_k_m-00001-of-00014.gguf}"
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
export MODEL_ALIAS="${MODEL_ALIAS:-qwen2.5-72b}"
export PARALLEL="${PARALLEL:-1}"
# Default 86016 (YaRN x2.625). Override CTX_SIZE=65536 to free margin if OOM.
export CTX_SIZE="${CTX_SIZE:-86016}"
export LOAD_TIMEOUT="${LOAD_TIMEOUT:-1800}"
export SLOT_CACHE_DIR="${SLOT_CACHE_DIR:-$(bash "$COMMON/default-slot-cache-dir-111.sh" "$REPO_DIR")}"
export COORDINATOR_LOOPBACK_LOCAL_SHARD=127.0.0.1:31353

# YaRN when past native 32k (HF Qwen2.5-72B-Instruct processing-long-texts).
unset ROPE_SCALING_TYPE ROPE_SCALE YARN_ORIG_CTX || true
if [[ "$CTX_SIZE" -gt 32768 ]]; then
  export ROPE_SCALING_TYPE=yarn
  ROPE_SCALE="$(awk -v c="$CTX_SIZE" 'BEGIN { printf "%.6g", c / 32768 }')"
  export ROPE_SCALE
  export YARN_ORIG_CTX=32768
fi

echo "== GREV72 MODELS_DIR=$MODELS_DIR MODEL_FILE=$MODEL_FILE PARALLEL=$PARALLEL CTX_SIZE=$CTX_SIZE =="
if [[ -n "${ROPE_SCALING_TYPE:-}" ]]; then
  echo "== GREV72 YaRN ROPE_SCALE=$ROPE_SCALE YARN_ORIG_CTX=$YARN_ORIG_CTX =="
fi

if [[ ! -f "$MODELS_DIR/$MODEL_FILE" ]]; then
  echo "ERROR: missing GGUF $MODELS_DIR/$MODEL_FILE - seed with: sudo bash scripts/hub_hub_models.sh pull gguf72" >&2
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
echo "== write-grev72-pool-env: shards from $inference_SHARDS_FILE =="

bash "$COMMON/write-grev27-pool-env-from-shards.sh"

# Append YaRN knobs for CTX > 32k (read by docker-compose.rpc-main.grev72-yarn.yml).
ENV_RPC="$LLC/.env.rpc"
if [[ -n "${ROPE_SCALING_TYPE:-}" ]]; then
  {
    echo "ROPE_SCALING_TYPE=$ROPE_SCALING_TYPE"
    echo "ROPE_SCALE=$ROPE_SCALE"
    echo "YARN_ORIG_CTX=$YARN_ORIG_CTX"
  } >>"$ENV_RPC"
  echo "== GREV72 appended YaRN to $ENV_RPC =="
fi
