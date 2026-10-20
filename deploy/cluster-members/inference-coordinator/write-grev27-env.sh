#!/usr/bin/env bash
# Write G-rev27 .env.rpc for dual-GPU + CPU spill on inference (:31358).
#
# Official: https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md
#   Layer split -ts 1,2; omit N_GPU_LAYERS and CTX_SIZE so --fit sizes VRAM + CPU spill.
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/write-grev27-env.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
ENV_RPC="$REPO_DIR/deploy/llamacpp-rpc/.env.rpc"

MODELS_DIR="${MODELS_DIR:-/mnt/cluster/llama-cpp/models}"
if [[ ! -d "$MODELS_DIR" ]]; then
  MODELS_DIR="${HOME}/alfa-ai-cache/llama-cpp/models"
fi

# Load timeouts (seconds). Official docs silent on 27B load time; cluster baseline:
# ~17 GB GGUF over NFS mmap + fit probe: allow 10 min (3060 preflight), 15 min (dual-GPU).
GPU3050_UUID="${GPU3050_UUID:-GPU-791ef00b-66b5-32ee-5487-4dcc02a37bcd}"
GPU3060_UUID="${GPU3060_UUID:-GPU-4a1dad62-4955-7c2f-90b0-219bdd606cb7}"
GPU_UUIDS="${GPU3050_UUID},${GPU3060_UUID}"
LOAD_TIMEOUT_GPU1="${LOAD_TIMEOUT_GPU1:-600}"
LOAD_TIMEOUT_DUAL="${LOAD_TIMEOUT_DUAL:-900}"

mkdir -p "$(dirname "$ENV_RPC")"
cat >"$ENV_RPC" <<EOF
# G-rev27: Qwen3.6-27B dual-GPU layer split + CPU spill (inference)
# https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md
# Do NOT set N_GPU_LAYERS or CTX_SIZE -- --fit auto-sizes (GPU split + CPU spill).
MAIN_PORT=31358
PREFLIGHT_PORT=31359
MODELS_DIR=$MODELS_DIR
SLOT_CACHE_DIR=$REPO_DIR/deploy/llamacpp-rpc/slot-cache-148
MODEL_FILE=Qwen3.6-27B-Q4_K_M.gguf
MODEL_ALIAS=qwen3.6-27b
TENSOR_SPLIT=1,2
FIT_TARGET_GPU1=1536
FIT_TARGET=512,1536
FIT_CTX=2048
GPU3050_UUID=$GPU3050_UUID
GPU3060_UUID=$GPU3060_UUID
GPU_UUIDS=$GPU_UUIDS
LOAD_TIMEOUT_GPU1=$LOAD_TIMEOUT_GPU1
LOAD_TIMEOUT_DUAL=$LOAD_TIMEOUT_DUAL
THREADS=12
CACHE_TYPE_K=q8_0
CACHE_TYPE_V=q8_0
PARALLEL=1
CHAT_TEMPLATE=chatml
THREADS_HTTP=8
LLAMA_API_KEY=change-me
CUDA_VISIBLE_DEVICES=0,1
RPC_BACKENDS=127.0.0.1:1
EOF

echo "Wrote G-rev27 env to $ENV_RPC"
echo "  load timeouts: GPU1 preflight=${LOAD_TIMEOUT_GPU1}s dual=${LOAD_TIMEOUT_DUAL}s"
if [[ ! -f "$MODELS_DIR/Qwen3.6-27B-Q4_K_M.gguf" ]]; then
  echo "ERROR: GGUF missing at $MODELS_DIR/Qwen3.6-27B-Q4_K_M.gguf" >&2
  exit 1
fi
