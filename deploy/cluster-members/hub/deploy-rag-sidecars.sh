#!/usr/bin/env bash
# hub hub -- Phase E1 RAG sidecars (embed GPU + rerank llama-server).
#
# Usage (SSH as operator on hub, one role at a time):
#   sudo bash deploy/cluster-members/hub/deploy-rag-sidecars.sh embed
#   sudo bash deploy/cluster-members/hub/deploy-rag-sidecars.sh rerank
#   sudo bash deploy/cluster-members/hub/deploy-rag-sidecars.sh all
#
# After deploy, set in deploy/.env on hub:
#   EMBED_BASE_URL=http://hub
#   RERANK_BASE_URL=http://hub
# Then recreate alfa-ai-litellm.
set -euo pipefail

ROLE="${1:-all}"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLC="$REPO_DIR/deploy/llamacpp-rpc"

embed_up() {
  echo "== Phase E1: embed Ollama GPU sidecar (:11435) =="
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: docker not reachable" >&2
    exit 1
  fi
  mkdir -p /mnt/ssd/ollama-embed 2>/dev/null || true
  cd "$SCRIPT_DIR"
  sudo docker compose -f docker-compose.embed-gpu.yml up -d --pull missing
  echo "Pull qwen3-embedding:4b from hub or ollama (hub-first)..."
  if [[ -d /mnt/cluster/models/ollama ]]; then
    echo "Hub ollama tree present under /mnt/cluster/models/ollama -- merge if needed."
  fi
  sudo docker exec alfa-ai-embed-ollama ollama pull qwen3-embedding:4b || true
  curl -fsS --max-time 30 http://127.0.0.1:11435/api/tags >/dev/null
  echo "embed sidecar OK on :11435"
}

rerank_up() {
  echo "== Phase E1: rerank llama-server sidecar (:8360) =="
  RERANK_DIR="/mnt/hub/alfa-ai/models/downloads/reranker"
  COMMON="$(cd "$SCRIPT_DIR/../_common" && pwd)"
  # shellcheck source=../_common/pick-qwen3-reranker-model.sh
  source "$COMMON/pick-qwen3-reranker-model.sh"
  export RERANK_MODELS_DIR="$RERANK_DIR"
  pick_qwen3_reranker_model
  export RERANK_MODEL_FILE RERANK_MODEL_ALIAS
  if [[ -d "$LLC" ]]; then
    COMMON="$(cd "$SCRIPT_DIR/../_common" && pwd)"
    bash "$COMMON/sync-llamacpp-vendor-from-hub.sh" "$REPO_DIR" || true
    if ! docker image inspect alfa-llamacpp-rpc:cuda128 >/dev/null 2>&1; then
      if [[ -f /mnt/hub/alfa-ai/docker-images/alfa-llamacpp-rpc-cuda128-b10355.tar.gz ]]; then
        sudo docker load -i /mnt/hub/alfa-ai/docker-images/alfa-llamacpp-rpc-cuda128-b10355.tar.gz
      fi
    fi
  fi
  cd "$SCRIPT_DIR"
  sudo docker compose -f docker-compose.reranker.yml up -d --no-build
  curl -fsS --max-time 120 http://127.0.0.1:8360/health
  echo "rerank sidecar OK on :8360"
}

rerank_down() {
  echo "== stop rerank sidecar (:8360) =="
  cd "$SCRIPT_DIR"
  sudo docker update --restart=no alfa-ai-reranker 2>/dev/null || true
  sudo docker compose -f docker-compose.reranker.yml down --remove-orphans 2>/dev/null || true
  sudo docker stop alfa-ai-reranker 2>/dev/null || true
  sudo docker rm -f alfa-ai-reranker 2>/dev/null || true
}

embed_down() {
  echo "== stop embed sidecar (:11435) =="
  cd "$SCRIPT_DIR"
  sudo docker update --restart=no alfa-ai-embed-ollama 2>/dev/null || true
  sudo docker compose -f docker-compose.embed-gpu.yml down --remove-orphans 2>/dev/null || true
  sudo docker stop alfa-ai-embed-ollama 2>/dev/null || true
  sudo docker rm -f alfa-ai-embed-ollama 2>/dev/null || true
}

case "$ROLE" in
  embed) embed_up ;;
  rerank) rerank_up ;;
  stop)
    embed_down
    rerank_down
    echo "RAG sidecars stopped on hub"
    ;;
  all)
    embed_up
    rerank_up
    ;;
  *)
    echo "Usage: $0 embed|rerank|all|stop" >&2
    exit 1
    ;;
esac

if [[ "$ROLE" != "stop" ]]; then
  echo "Update deploy/.env EMBED_BASE_URL / RERANK_BASE_URL and recreate alfa-ai-litellm."
fi
