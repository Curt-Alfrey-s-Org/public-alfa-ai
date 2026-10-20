#!/usr/bin/env bash
# Standalone llama-server for Qwen2.5-Coder-7B + optional LoRA on gaming-c (:8470).
#
# Not RPC. Official: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
set -euo pipefail

MAIN_PORT="${MAIN_PORT:-8470}"
MODEL_FILE="${MODEL_FILE:-Qwen2.5-Coder-7B-Instruct-Q8_0.gguf}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen2.5-coder-7b}"
CTX_SIZE="${CTX_SIZE:-8192}"
BATCH_SIZE="${BATCH_SIZE:-2048}"
UBATCH_SIZE="${UBATCH_SIZE:-512}"
N_GPU_LAYERS="${N_GPU_LAYERS:-999}"
CHAT_TEMPLATE="${CHAT_TEMPLATE:-chatml}"
PARALLEL="${PARALLEL:-2}"
THREADS_HTTP="${THREADS_HTTP:-8}"
HUB_ROOT="${LLAMA_7B_HUB_ROOT:-/hub}"
MODELS_SUBDIR="${LLAMA_7B_MODELS_SUBDIR:-models/qwen25-coder-7b}"
LORA_SUBDIR="${LLAMA_7B_LORA_SUBDIR:-lora/qwen25-coder-7b}"
LORA_GGUF="${LORA_GGUF:-}"
LORA_SCALE="${LORA_SCALE:-1.0}"

model_path="${HUB_ROOT}/${MODELS_SUBDIR}/${MODEL_FILE}"
if [[ ! -f "$model_path" ]]; then
  echo "ERROR: missing base GGUF $model_path (hub NFS ${HUB_ROOT}/${MODELS_SUBDIR}/)" >&2
  exit 1
fi

args=(
  llama-server
  --host "0.0.0.0"
  --port "${MAIN_PORT}"
  --model "${model_path}"
  --alias "${MODEL_ALIAS}"
  --ctx-size "${CTX_SIZE}"
  --batch-size "${BATCH_SIZE}"
  --ubatch-size "${UBATCH_SIZE}"
  --n-gpu-layers "${N_GPU_LAYERS}"
  --flash-attn on
  --no-warmup
  --jinja
  --chat-template "${CHAT_TEMPLATE}"
  --parallel "${PARALLEL}"
  --threads-http "${THREADS_HTTP}"
)

if [[ -n "${LORA_GGUF}" ]]; then
  lora_path="${HUB_ROOT}/${LORA_SUBDIR}/${LORA_GGUF}"
  if [[ ! -f "${lora_path}" ]]; then
    echo "ERROR: LORA_GGUF set but missing file ${lora_path}" >&2
    exit 1
  fi
  echo "== 7B serve LoRA: ${lora_path} scale=${LORA_SCALE} =="
  if [[ "${LORA_SCALE}" == "1.0" ]] || [[ "${LORA_SCALE}" == "1" ]]; then
    args+=(--lora "${lora_path}")
  else
    # Official: --lora-scaled FNAME:SCALE
    # https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
    args+=(--lora-scaled "${lora_path}:${LORA_SCALE}")
  fi
fi

exec "${args[@]}"
