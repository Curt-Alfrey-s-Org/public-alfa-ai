#!/usr/bin/env bash
# Start llama-server coordinator with optional LoRA adapter.
#
# Reads env from docker-compose (.env.rpc). Appends --lora when LORA_GGUF is set.
# Official: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
#
# Mounted by docker-compose.rpc-main.grev27-pool-coordinator.yml
set -euo pipefail

MAIN_PORT="${MAIN_PORT:-31360}"
MODEL_FILE="${MODEL_FILE:-Qwen3.8-27B-Q8_0.gguf}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen3.6-27b}"
CTX_SIZE="${CTX_SIZE:-262144}"
BATCH_SIZE="${BATCH_SIZE:-8192}"
UBATCH_SIZE="${UBATCH_SIZE:-1024}"
CACHE_TYPE_K="${CACHE_TYPE_K:-q4_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q4_0}"
N_GPU_LAYERS="${N_GPU_LAYERS:-999}"
TENSOR_SPLIT="${TENSOR_SPLIT:-12,8,10,5}"
CHAT_TEMPLATE="${CHAT_TEMPLATE:-chatml}"
PARALLEL="${PARALLEL:-5}"
THREADS_HTTP="${THREADS_HTTP:-64}"
CACHE_REUSE="${CACHE_REUSE:-256}"
# Server prompt cache must stay off on RPC coordinators: saving a slot calls
# state_seq_get_data(), which cannot read KV owned by the RPC backend and aborts
# the server. Upstream #26128 / #26529; see docs/inference_RPC_RELIABILITY.md item 6.
CACHE_RAM="${CACHE_RAM:-0}"
LORA_MODELS_DIR="${LORA_MODELS_DIR:-/models/lora}"
LORA_GGUF="${LORA_GGUF:-}"
LORA_SCALE="${LORA_SCALE:-1.0}"

if [[ -z "${RPC_BACKENDS:-}" ]]; then
  echo "ERROR: RPC_BACKENDS must be set in .env.rpc" >&2
  exit 1
fi

args=(
  llama-server
  --host "0.0.0.0"
  --port "${MAIN_PORT}"
  --model "/models/${MODEL_FILE}"
  --alias "${MODEL_ALIAS}"
  --ctx-size "${CTX_SIZE}"
  --batch-size "${BATCH_SIZE}"
  --ubatch-size "${UBATCH_SIZE}"
  --cache-type-k "${CACHE_TYPE_K}"
  --cache-type-v "${CACHE_TYPE_V}"
  --n-gpu-layers "${N_GPU_LAYERS}"
  --tensor-split "${TENSOR_SPLIT}"
  --split-mode layer
  --main-gpu "0"
  --flash-attn on
  --no-warmup
  --fit off
  --no-mmap
  --rpc "${RPC_BACKENDS}"
  --jinja
  --chat-template "${CHAT_TEMPLATE}"
  --parallel "${PARALLEL}"
  --threads-http "${THREADS_HTTP}"
  --cache-reuse "${CACHE_REUSE}"
  --cache-ram "${CACHE_RAM}"
  --slot-save-path "/slot-cache"
  # Official Prometheus exporter (default off). Grafana on monitor scrapes
  # GET /metrics with Bearer LLAMA_API_KEY. Docs: inference_PERF_AND_SHARDS.md
  # https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
  --metrics
)

if [[ -n "${LORA_GGUF}" ]]; then
  lora_path="${LORA_MODELS_DIR}/${LORA_GGUF}"
  if [[ ! -f "${lora_path}" ]]; then
    echo "ERROR: LORA_GGUF set but missing file ${lora_path}" >&2
    exit 1
  fi
  echo "== coordinator LoRA: ${lora_path} scale=${LORA_SCALE} =="
  if [[ "${LORA_SCALE}" == "1.0" ]] || [[ "${LORA_SCALE}" == "1" ]]; then
    args+=(--lora "${lora_path}")
  else
    args+=(--lora-scaled "${lora_path}" "${LORA_SCALE}")
  fi
fi

exec "${args[@]}"
