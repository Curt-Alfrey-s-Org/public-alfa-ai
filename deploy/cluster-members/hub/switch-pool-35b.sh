#!/usr/bin/env bash
# Phase H: switch pool to 35B MoE (pool35 .env on hub; coordinator via deploy-grev35-coordinator.sh).
#
# Mutual exclusion: stops 27B pool coordinator. Shared GPU shards stay up (same as inference).
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/switch-pool-35b.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"

_set_env_kv() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sudo sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" | sudo tee -a "$ENV_FILE" >/dev/null
  fi
}

ENV_FILE="$REPO_DIR/deploy/.env"
# Sentinel :31399 marks 27B inactive in picker while pool35 uses :31360
WANT_CODE27_URL='http://127.0.0.1:31399/v1'
WANT_35B_URL='http://127.0.0.1:31360/v1'
WANT_EMBED_URL='http://orchestrator'
WANT_RERANK_URL='http://orchestrator'

echo "== switch-pool-35b: stop 27B pool coordinator =="
sudo docker stop llamacpp-server-111-grev27-pool llamacpp-server 2>/dev/null || true
sudo docker rm -f llamacpp-server-111-grev27-pool llamacpp-server 2>/dev/null || true

echo "== switch-pool-35b: pool35 LiteLLM env =="
if [[ -f "$ENV_FILE" ]]; then
  if grep -q '^LLAMACPP_CODE27_URL=' "$ENV_FILE"; then
    sudo sed -i "s|^LLAMACPP_CODE27_URL=.*|LLAMACPP_CODE27_URL=${WANT_CODE27_URL}|" "$ENV_FILE"
  else
    echo "LLAMACPP_CODE27_URL=${WANT_CODE27_URL}" | sudo tee -a "$ENV_FILE" >/dev/null
  fi
  if grep -q '^LLAMACPP_35B_URL=' "$ENV_FILE"; then
    sudo sed -i "s|^LLAMACPP_35B_URL=.*|LLAMACPP_35B_URL=${WANT_35B_URL}|" "$ENV_FILE"
  else
    echo "LLAMACPP_35B_URL=${WANT_35B_URL}" | sudo tee -a "$ENV_FILE" >/dev/null
  fi
  _set_env_kv ALFA_INFERENCE_MODE default
  _set_env_kv CHAT_MODELS 'fast,qwen3.6:35b-a3b'
  _set_env_kv DEFAULT_MODEL fast
  _set_env_kv LITELLM_CONFIG litellm_config.pool35.yaml
  _set_env_kv EMBED_BASE_URL "$WANT_EMBED_URL"
  _set_env_kv RERANK_BASE_URL "$WANT_RERANK_URL"
  echo "Updated deploy/.env for pool35 (sentinel CODE27 URL, speed tier on :31360)"
fi

echo "== switch-pool-35b complete =="
echo "Next: deploy-grev35-coordinator.sh (or operator-cluster-111.sh start-pool35)."
