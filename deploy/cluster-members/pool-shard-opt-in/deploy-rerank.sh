#!/usr/bin/env bash
# VM100 — deploy rerank llama-server (:8360) on shared 1660S with embed.
#
# RETIRED for inference: VM100 1660S is shard-only; production RAG on rag CPU.
# Requires Qwen3-Reranker-0.6B GGUF on hub/NFS (no BGE fallback).
set -euo pipefail

# RETIRED 2026-07-09: VM100 is inference-shard-only; production RAG runs on rag
# (deploy/cluster-members/rag-host). Running this would contend with the shard
# for the 1660S. Rollback only, and only with an explicit opt-in.
if [[ "${ALLOW_LEGACY_VM100_RAG:-0}" != "1" ]]; then
  echo "ERROR: RAG on pool-opt-in is retired (VM100 is inference-shard-only; RAG is on rag)." >&2
  echo "  Production: bash deploy/cluster-members/rag-host/deploy-rag-cpu.sh (on rag)" >&2
  echo "  Rollback only: ALLOW_LEGACY_VM100_RAG=1 bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMMON="$REPO_ROOT/deploy/cluster-members/_common"
ENV_FILE="$SCRIPT_DIR/.env.embed"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: missing $ENV_FILE — copy from .env.embed.example" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

RERANK_DIR="${RERANK_MODELS_DIR:-/mnt/cluster/models/downloads/reranker}"
export RERANK_MODELS_DIR="$RERANK_DIR"

if [[ -x "$REPO_ROOT/scripts/mount_nfs_models.sh" ]]; then
  bash "$REPO_ROOT/scripts/mount_nfs_models.sh" || true
fi

# shellcheck source=../_common/pick-qwen3-reranker-model.sh
source "$COMMON/pick-qwen3-reranker-model.sh"
pick_qwen3_reranker_model
bash "$COMMON/load-llamacpp-rpc-from-hub.sh" "$REPO_ROOT"

# llama-server SIGILLs without AVX2 (Proxmox default qemu64 CPU hides host AVX2).
HOST_LABEL=100 bash "$COMMON/preflight-cpu-avx2.sh"

# Embed may already hold ~2.5 GiB; allow headroom for rerank load on 6 GiB card.
HOST_LABEL=100 MAX_MIB=4096 bash "$COMMON/preflight-gpu-empty.sh"

cd "$SCRIPT_DIR"
echo "== VM100 rerank sidecar (:8360, shared 1660S) =="
docker compose --env-file .env.embed -f docker-compose.reranker.yml up -d --no-build

bash "$COMMON/wait-http.sh" "http://127.0.0.1:${RERANK_PORT:-8360}/health" 120
bash "$COMMON/assert-rpc-server-cuda.sh" alfa-ai-reranker
echo "rerank sidecar OK on pool-opt-in:${RERANK_PORT:-8360} (alias=${RERANK_MODEL_ALIAS})"
