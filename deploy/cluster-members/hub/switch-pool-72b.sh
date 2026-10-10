#!/usr/bin/env bash
# Exclusive Qwen2.5-72B dense: LiteLLM frontier on coordinator :31360.
#
# Mutual exclusion with 27B: same port; stop 27B coordinator before load
# (deploy-grev72-pool-coordinator.sh recreates the container).
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/switch-pool-72b.sh
#
# Docs: docs/GREV72_72B_OPERATOR.md
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
WANT_CODE27_URL='http://host.docker.internal:31360/v1'
WANT_EMBED_URL='http://orchestrator'
WANT_RERANK_URL='http://orchestrator'

echo "== switch-pool-72b: LiteLLM frontier = Qwen2.5-72B exclusive =="
if [[ -f "$ENV_FILE" ]]; then
  if grep -q '^LLAMACPP_CODE27_URL=' "$ENV_FILE"; then
    sudo sed -i "s|^LLAMACPP_CODE27_URL=.*|LLAMACPP_CODE27_URL=${WANT_CODE27_URL}|" "$ENV_FILE"
  else
    echo "LLAMACPP_CODE27_URL=${WANT_CODE27_URL}" | sudo tee -a "$ENV_FILE" >/dev/null
  fi
  _set_env_kv ALFA_INFERENCE_MODE pool72
  _set_env_kv CHAT_MODELS 'frontier,qwen2.5-72b'
  _set_env_kv DEFAULT_MODEL frontier
  _set_env_kv LITELLM_CONFIG litellm_config.pool72.yaml
  _set_env_kv EMBED_BASE_URL "$WANT_EMBED_URL"
  _set_env_kv RERANK_BASE_URL "$WANT_RERANK_URL"
  echo "Updated deploy/.env for pool72 (frontier on :31360)"
else
  echo "WARN: missing $ENV_FILE — create from env.example before brain start" >&2
fi

echo "== switch-pool-72b complete =="
echo "Next: deploy-grev72-pool-coordinator.sh (or operator-cluster-111.sh start-pool72)."
