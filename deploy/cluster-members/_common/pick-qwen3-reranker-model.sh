#!/usr/bin/env bash
# Require Qwen3-Reranker-0.6B GGUF on hub/NFS. No BGE or other-family fallback.
#
# Usage (sourced from deploy scripts):
#   source deploy/cluster-members/_common/pick-qwen3-reranker-model.sh
#   pick_qwen3_reranker_model
#
# Sets: RERANK_MODEL_FILE, RERANK_MODEL_ALIAS=qwen3-reranker-0.6b
# Env:  RERANK_MODELS_DIR (prefer ~/alfa-ai-cache/rag/reranker; hub NFS is seed)
#
# Hub seed (hub only): scripts/seed-qwen3-reranker-gguf-hub.sh
# Official model card: https://huggingface.co/Qwen/Qwen3-Reranker-0.6B
set -euo pipefail

pick_qwen3_reranker_model() {
  local dir="${1:-${RERANK_MODELS_DIR:-/mnt/cluster/models/downloads/reranker}}"
  local qwen qwen_glob

  if [[ ! -d "$dir" ]]; then
    echo "ERROR: reranker models dir missing: $dir" >&2
    echo "  Seed on hub: sudo bash scripts/seed-qwen3-reranker-gguf-hub.sh" >&2
    echo "  NFS clients read: /mnt/cluster/models/downloads/reranker/" >&2
    return 1
  fi

  for qwen in \
    Qwen3-Reranker-0.6B-Q8_0.gguf \
    Qwen3-Reranker-0.6B-Q4_K_M.gguf \
    Qwen3-Reranker-0.6B.Q4_K_M.gguf \
    Qwen3-Reranker-0.6B.Q8_0.gguf \
    Qwen3-Reranker-0.6B.gguf; do
    if [[ -f "$dir/$qwen" ]]; then
      export RERANK_MODEL_FILE="$qwen"
      export RERANK_MODEL_ALIAS="qwen3-reranker-0.6b"
      echo "Using Qwen3 reranker: $qwen"
      return 0
    fi
  done

  for qwen_glob in "$dir"/Qwen3-Reranker*.gguf; do
    if [[ -f "$qwen_glob" ]]; then
      export RERANK_MODEL_FILE="$(basename "$qwen_glob")"
      export RERANK_MODEL_ALIAS="qwen3-reranker-0.6b"
      echo "Using Qwen3 reranker: $RERANK_MODEL_FILE"
      return 0
    fi
  done

  echo "ERROR: no Qwen3-Reranker GGUF under $dir (BGE fallback removed)" >&2
  echo "  Seed on hub: sudo bash scripts/seed-qwen3-reranker-gguf-hub.sh" >&2
  echo "  Official: https://huggingface.co/Qwen/Qwen3-Reranker-0.6B" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  pick_qwen3_reranker_model "${1:-}"
  echo "  RERANK_MODEL_FILE=$RERANK_MODEL_FILE"
  echo "  RERANK_MODEL_ALIAS=$RERANK_MODEL_ALIAS"
fi
