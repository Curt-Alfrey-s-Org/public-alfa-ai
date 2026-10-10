#!/usr/bin/env bash
# inference -- deploy rerank llama-server on RTX 3050 (:8360).
#
# RETIRED for inference: RAG rerank moved to CPU via deploy-rag-cpu.sh.
# This script remains for legacy GPU-rerank repair only.
#
# Requires Qwen3-Reranker-0.6B GGUF on hub/NFS (no BGE fallback).
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/deploy-rag-rerank.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"
LLC="$REPO_DIR/deploy/llamacpp-rpc"

bash "$COMMON/preflight-docker-engine.sh"

RERANK_DIR="${RERANK_MODELS_DIR:-/mnt/cluster/models/downloads/reranker}"
export RERANK_MODELS_DIR="$RERANK_DIR"

# shellcheck source=../_common/pick-qwen3-reranker-model.sh
source "$COMMON/pick-qwen3-reranker-model.sh"
pick_qwen3_reranker_model

bash "$COMMON/load-llamacpp-rpc-from-hub.sh"

cd "$SCRIPT_DIR"
echo "== Phase E1: rerank sidecar on 3050 (:8360) =="
docker compose -f docker-compose.reranker-3050.yml up -d --no-build --force-recreate

bash "$COMMON/wait-http.sh" "http://127.0.0.1:${RERANK_PORT:-8360}/health" 120
bash "$COMMON/assert-rpc-server-cuda.sh" alfa-ai-reranker
echo "rerank sidecar OK on inference:8360 (alias=$RERANK_MODEL_ALIAS)"
echo "Set on hub deploy/.env: RERANK_BASE_URL=http://orchestrator"
