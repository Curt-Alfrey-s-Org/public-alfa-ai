#!/usr/bin/env bash
# Remove retired qwen3:4b, qwen3:8b, and qwen3-coder:30b-a3b-q4_K_M from local Ollama.
# Hub blobs stay on hub (scripts/hub_hub_models.sh LEGACY_OLLAMA_TAGS).
#
# Usage:
#   bash deploy/cluster-members/_common/remove-ollama-qwen3-4b-8b.sh
#   sudo bash deploy/cluster-members/_common/remove-ollama-qwen3-4b-8b.sh --recreate-litellm
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
STACKS_DIR="${ALFA_DOCKGE_STACKS_DIR:-/mnt/HDDs/apps/Dockge}"
RECREATE_LITELLM=0

for arg in "$@"; do
  case "$arg" in
    --recreate-litellm) RECREATE_LITELLM=1 ;;
  esac
done

tags=(qwen3:4b qwen3:8b qwen3-coder:30b-a3b-q4_K_M qwen3.5:27b)

if ! curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "Ollama not reachable on :11434 — nothing to remove."
  exit 0
fi

present=$(curl -fsS http://127.0.0.1:11434/api/tags | python3 -c 'import json,sys; print("\n".join(m["name"] for m in json.load(sys.stdin).get("models",[])))')

for tag in "${tags[@]}"; do
  if printf '%s\n' "$present" | grep -Fxq "$tag"; then
    echo "Removing $tag ..."
    if command -v ollama >/dev/null 2>&1; then
      if [[ "$(id -u)" -eq 0 ]]; then
        sudo -u ollama ollama rm "$tag" 2>/dev/null || ollama rm "$tag" || true
      else
        ollama rm "$tag" 2>/dev/null || \
          curl -fsS -X DELETE http://127.0.0.1:11434/api/delete -d "{\"name\":\"$tag\"}" || true
      fi
    else
      curl -fsS -X DELETE http://127.0.0.1:11434/api/delete -d "{\"name\":\"$tag\"}" || true
    fi
  else
    echo "Skip $tag (not installed locally)"
  fi
done

echo ""
echo "Remaining models:"
curl -fsS http://127.0.0.1:11434/api/tags | \
  python3 -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(m["name"] for m in d.get("models",[])) or "(none)")'

if [[ "$RECREATE_LITELLM" -eq 1 ]]; then
  DEPLOY_DIR="$REPO_DIR/deploy"
  ENV_FILE="$DEPLOY_DIR/.env"
  if [[ ! -f "$ENV_FILE" && -f "$STACKS_DIR/alfa-ai/.env" ]]; then
    DEPLOY_DIR="$STACKS_DIR/alfa-ai"
    ENV_FILE="$DEPLOY_DIR/.env"
  fi
  if [[ -f "$ENV_FILE" ]]; then
    echo "Recreating alfa-ai-litellm from $DEPLOY_DIR ..."
    cd "$DEPLOY_DIR"
    if docker info >/dev/null 2>&1; then
      docker compose --env-file "$ENV_FILE" -f docker-compose.yml up -d --force-recreate alfa-ai-litellm
    else
      sudo docker compose --env-file "$ENV_FILE" -f docker-compose.yml up -d --force-recreate alfa-ai-litellm
    fi
    bash "$REPO_DIR/deploy/cluster-members/_common/wait-litellm-liveliness.sh" 180 || true
  else
    echo "WARN: no deploy/.env found; skip LiteLLM recreate"
  fi
fi

echo "Done. Hub copies of retired tags are unchanged on hub."
