#!/usr/bin/env bash
set -euo pipefail
#
# Host hub (hub) — single entry point to build/start the brain stack + hub.
# (Petals GPU worker / petals-gateway are retired; inference is llama.cpp inference.)
#
# Runs deploy.sh in this directory, which:
#   - Loads hub Docker tarballs (unless --skip-images)
#   - Brings up registry mirror (:5000)
#   - Ensures tunnel_network
#   - Verifies LiteLLM cosign (unless skipped via env in deploy.sh)
#   - docker compose up brain stack (API :8420, LiteLLM, nginx)
#
# Does NOT manage Dockge (hub Apps) or Ollama App — see docs/DOCKGE_111_OPERATOR.md.
#
# Usage:
#   cd /mnt/hub/alfa-ai/repo/alfa-ai
#   bash deploy/cluster-members/hub/build-start-alfa-ai-111.sh
#   bash deploy/cluster-members/hub/build-start-alfa-ai-111.sh --skip-pull
#   bash deploy/cluster-members/hub/build-start-alfa-ai-111.sh --skip-images
#   bash deploy/cluster-members/hub/build-start-alfa-ai-111.sh --registry-only
#
# Docker socket: deploy.sh uses docker then sudo docker; or run:
#   sudo bash deploy/cluster-members/hub/build-start-alfa-ai-111.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/deploy.sh"
if [[ ! -f "$DEPLOY" ]]; then
  echo "ERROR: missing sibling deploy.sh: $DEPLOY" >&2
  exit 1
fi

echo ""
echo "== build-start-alfa-ai-111 -> deploy.sh =="
echo "   Brain: API + LiteLLM + nginx (deploy/docker-compose.yml); Postgres/Redis are separate protected stacks"
echo "   Hub:   registry mirror (:5000), hub image load, tunnel_network"
echo "   RAG:   rag (EMBED_BASE_URL / RERANK_BASE_URL in deploy/.env)"
echo ""
echo "   Docs:  docs/DOCKGE_111_OPERATOR.md"
echo ""

exec bash "$DEPLOY" "$@"
