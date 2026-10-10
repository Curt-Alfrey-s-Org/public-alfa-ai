#!/usr/bin/env bash
# VM100 — LEGACY GPU embed sidecar (:11435). RETIRED — see guard below.
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
ENV_FILE="$SCRIPT_DIR/.env.embed"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: missing $ENV_FILE — copy from .env.embed.example" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found — configure 1660S passthrough on VM100 first" >&2
  exit 1
fi

if [[ -x "$REPO_ROOT/scripts/mount_nfs_models.sh" ]]; then
  bash "$REPO_ROOT/scripts/mount_nfs_models.sh" || true
fi

export OLLAMA_EMBED_MODELS_DIR="${OLLAMA_EMBED_MODELS_DIR:-/mnt/cluster/models/ollama-embed}"
if ! mkdir -p "$OLLAMA_EMBED_MODELS_DIR" 2>/dev/null && ! sudo mkdir -p "$OLLAMA_EMBED_MODELS_DIR" 2>/dev/null; then
  OLLAMA_EMBED_MODELS_DIR="${HOME}/ollama-embed"
  mkdir -p "$OLLAMA_EMBED_MODELS_DIR"
  echo "WARN: NFS embed path not writable — using local $OLLAMA_EMBED_MODELS_DIR"
  export OLLAMA_EMBED_MODELS_DIR
fi

cd "$SCRIPT_DIR"
echo "== VM100 embed sidecar (:11435) =="
docker compose --env-file .env.embed -f docker-compose.embed-gpu.yml up -d --pull missing

echo "Pull qwen3-embedding:4b..."
docker exec alfa-ai-embed-ollama ollama pull qwen3-embedding:4b || true

curl -fsS --max-time 30 http://127.0.0.1:11435/api/tags >/dev/null
echo "LEGACY embed sidecar OK on pool-opt-in:11435 (rollback mode)"
echo "Production RAG is rag: EMBED_BASE_URL=http://orchestrator RERANK_BASE_URL=http://orchestrator"
echo "Only repoint hub deploy/.env at pool-opt-in for an explicit rollback; then recreate alfa-ai-litellm"