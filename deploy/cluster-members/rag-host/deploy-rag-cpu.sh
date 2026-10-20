#!/usr/bin/env bash
# rag -- deploy CPU RAG sidecars (embed :11435 + rerank :8360).
#
# CPU-only VM: no NVIDIA passthrough. Rerank uses official ghcr.io/ggml-org/llama.cpp:server
# (see docker-compose.reranker-cpu.yml). inference keeps alfa-llamacpp-rpc:cuda128 + host driver.
#
# Usage (on rag):
#   bash deploy/cluster-members/rag-host/deploy-rag-cpu.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

bash "$COMMON/preflight-docker-engine.sh"
bash "$COMMON/preflight-cpu-avx2.sh"

echo "== stop any stale RAG containers on rag =="
docker stop alfa-ai-reranker alfa-ai-embed-ollama 2>/dev/null || true
docker rm -f alfa-ai-reranker alfa-ai-embed-ollama 2>/dev/null || true

if [[ -n "${RERANK_MODELS_DIR:-}" && -n "${OLLAMA_EMBED_MODELS_DIR:-}" ]]; then
  export RERANK_MODELS_DIR
  export OLLAMA_EMBED_MODELS_DIR
  echo "  RAG models (env): rerank=$RERANK_MODELS_DIR embed=$OLLAMA_EMBED_MODELS_DIR"
else
  # shellcheck disable=SC1090
  eval "$(bash "$COMMON/ensure-rag-models-local-cache.sh" | grep -E '^export (RERANK_MODELS_DIR|OLLAMA_EMBED_MODELS_DIR)=')"
  echo "  RAG models (local cache): rerank=$RERANK_MODELS_DIR embed=$OLLAMA_EMBED_MODELS_DIR"
fi

# shellcheck source=../_common/pick-qwen3-reranker-model.sh
source "$COMMON/pick-qwen3-reranker-model.sh"
pick_qwen3_reranker_model

cd "$SCRIPT_DIR"
echo "== rag CPU embed sidecar (:11435) =="
docker compose -f docker-compose.embed-cpu.yml up -d --pull missing
if docker exec alfa-ai-embed-ollama ollama list 2>/dev/null | grep -q 'qwen3-embedding:4b'; then
  echo "  qwen3-embedding:4b already in local Ollama cache (skip pull)"
else
  echo "Pull qwen3-embedding:4b into local cache..."
  docker exec alfa-ai-embed-ollama ollama pull qwen3-embedding:4b || true
fi

echo "== rag CPU rerank sidecar (:8360, ghcr.io llama.cpp server) =="
docker compose -f docker-compose.reranker-cpu.yml up -d --pull missing --force-recreate

bash "$COMMON/wait-http.sh" "http://127.0.0.1:11435/api/tags" 120
bash "$COMMON/wait-http.sh" "http://127.0.0.1:${RERANK_PORT:-8360}/health" 180

echo "rag-cpu OK on rag (embed :11435 + rerank :8360, alias=$RERANK_MODEL_ALIAS)"
