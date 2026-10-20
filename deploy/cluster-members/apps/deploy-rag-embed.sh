#!/usr/bin/env bash
# LEGACY — embed moved to VM100 (Track B). Use deploy/cluster-members/pool-shard-opt-in/deploy-embed.sh
# and EMBED_BASE_URL=http://orchestrator on hub instead.
#
# apps -- deploy GPU embed sidecar on GTX 1660S (:11435) [retired after VM100 cutover].
#
# Usage (on apps, only if rolling back from VM100):
#   bash deploy/cluster-members/apps/deploy-rag-embed.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker not reachable" >&2
  exit 1
fi

echo "== stop Petals on apps (GPU mutual exclusion) =="
mkdir -p "$HOME/ollama-embed" 2>/dev/null || true
export OLLAMA_EMBED_MODELS_DIR="${OLLAMA_EMBED_MODELS_DIR:-$HOME/ollama-embed}"

cd "$SCRIPT_DIR"
echo "== Phase E1: embed Ollama GPU sidecar (:11435) =="
docker compose -f docker-compose.embed-gpu.yml up -d --pull missing

echo "Pull qwen3-embedding:4b (hub-first if models present under volume)..."
docker exec alfa-ai-embed-ollama ollama pull qwen3-embedding:4b || true

curl -fsS --max-time 30 http://127.0.0.1:11435/api/tags >/dev/null
echo "embed sidecar OK on apps:11435"
echo "Track B (current): on hub deploy/.env set EMBED_BASE_URL=http://orchestrator"
echo "Legacy data-plane (do not use for new deploys): http://orchestrator"
