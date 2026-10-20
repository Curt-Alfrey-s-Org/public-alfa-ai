#!/usr/bin/env bash
# inference -- deploy CPU RAG sidecars (embed :11435 + rerank :8360).
#
# RETIRED 2026-07-18: production RAG runs on rag
# (deploy/cluster-members/rag-host/deploy-rag-cpu.sh,
# docs/RAG_148_TO_110_MIGRATION.md). Keep this for rollback only.
#
# Moved off VM100 (GTX 1660 Super, now shard-only) and off the legacy inference
# GPU rerank (docker-compose.reranker-3050.yml, retired) so both inference GPUs
# (3060 :31356 + 5060 :31357) stay reserved for the inference rpc-server shards.
# See .cursor/plans/RAG_248_VM100_SHARD.md.
#
# Local-first: embed + rerank trees live under ~/alfa-ai-cache/rag after one
# promote from NFS (ensure-rag-models-local-cache.sh). Warm starts skip hub I/O.
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/deploy-rag-cpu.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

bash "$COMMON/preflight-docker-engine.sh"

echo "== stop legacy inference GPU rerank (retired, RAG now CPU-only) =="
docker stop alfa-ai-reranker 2>/dev/null || true
docker rm -f alfa-ai-reranker 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/docker-compose.reranker-3050.yml" ]]; then
  (cd "$SCRIPT_DIR" && docker compose -f docker-compose.reranker-3050.yml down --remove-orphans 2>/dev/null) || true
fi

# Prefer explicit env; else promote hub -> local cache once.
if [[ -n "${RERANK_MODELS_DIR:-}" && -n "${OLLAMA_EMBED_MODELS_DIR:-}" ]]; then
  export RERANK_MODELS_DIR
  export OLLAMA_EMBED_MODELS_DIR
  echo "  RAG models (env): rerank=$RERANK_MODELS_DIR embed=$OLLAMA_EMBED_MODELS_DIR"
else
  # Only eval export lines -- ensure script status/preflight goes to stderr.
  # shellcheck disable=SC1090
  eval "$(bash "$COMMON/ensure-rag-models-local-cache.sh" | grep -E '^export (RERANK_MODELS_DIR|OLLAMA_EMBED_MODELS_DIR)=')"
  echo "  RAG models (local cache): rerank=$RERANK_MODELS_DIR embed=$OLLAMA_EMBED_MODELS_DIR"
fi

# shellcheck source=../_common/pick-qwen3-reranker-model.sh
source "$COMMON/pick-qwen3-reranker-model.sh"
pick_qwen3_reranker_model
bash "$COMMON/load-llamacpp-rpc-from-hub.sh"

cd "$SCRIPT_DIR"
echo "== inference CPU embed sidecar (:11435) =="
docker compose -f docker-compose.embed-cpu.yml up -d --pull missing
# Warm local Ollama blob store: pull only if tag missing (avoids hub/registry I/O).
if docker exec alfa-ai-embed-ollama ollama list 2>/dev/null | grep -q 'qwen3-embedding:4b'; then
  echo "  qwen3-embedding:4b already in local Ollama cache (skip pull)"
else
  echo "Pull qwen3-embedding:4b into local cache..."
  docker exec alfa-ai-embed-ollama ollama pull qwen3-embedding:4b || true
fi

echo "== inference CPU rerank sidecar (:8360) =="
docker compose -f docker-compose.reranker-cpu.yml up -d --no-build --force-recreate

bash "$COMMON/wait-http.sh" "http://127.0.0.1:11435/api/tags" 120
bash "$COMMON/wait-http.sh" "http://127.0.0.1:${RERANK_PORT:-8360}/health" 120

echo "rag-cpu OK on inference (embed :11435 + rerank :8360, alias=$RERANK_MODEL_ALIAS)"
echo "NOTE: inference RAG is retired; production is rag (EMBED_BASE_URL=http://orchestrator)."
echo "Only for an explicit rollback: set hub deploy/.env EMBED_BASE_URL=http://orchestrator"
echo "RERANK_BASE_URL=http://orchestrator, then recreate alfa-ai-litellm."
