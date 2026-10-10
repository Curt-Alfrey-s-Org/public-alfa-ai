#!/usr/bin/env bash
# Phase H: switch pool to 27B (inference .env on hub; RAG on rag CPU — not deployed here).
#
# CPU coordinator on hub :31360; GPU shards on inference (:31356/:31357), orchestrator (:31350),
# VM100 (:31354), and hub RTX 3050 (:31353). Orchestrator starts RAG on rag after
# coordinator; then start-brain on hub. RAG on rag since 2026-07-18 cutover from inference
# -- see docs/RAG_148_TO_110_MIGRATION.md.
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/switch-pool-27b.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

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
WANT_35B_URL='http://orchestrator/v1'
WANT_EMBED_URL='http://orchestrator'
WANT_RERANK_URL='http://orchestrator'

echo "== switch-pool-27b: inference LiteLLM env (RAG URLs point at rag CPU) =="
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
  _set_env_kv ALFA_INFERENCE_MODE inference
  _set_env_kv CHAT_MODELS 'frontier-code,qwen3.6-27b'
  if [[ "${inference_MODEL_FILE:-}" == *Qwen3.6* ]]; then
    _set_env_kv ALFA_inference_FAMILY qwen36
  else
    _set_env_kv ALFA_inference_FAMILY qwen38
  fi
  _set_env_kv DEFAULT_MODEL frontier-code
  _set_env_kv ALFA_AI_AGENT_MODEL frontier-code
  _set_env_kv LITELLM_CONFIG litellm_config.inference.yaml
  _set_env_kv EMBED_BASE_URL "$WANT_EMBED_URL"
  _set_env_kv RERANK_BASE_URL "$WANT_RERANK_URL"
  echo "Updated LLAMACPP_CODE27_URL, LLAMACPP_35B_URL, EMBED_BASE_URL, RERANK_BASE_URL, ALFA_INFERENCE_MODE, CHAT_MODELS, ALFA_inference_FAMILY, ALFA_AI_AGENT_MODEL, DEFAULT_MODEL, LITELLM_CONFIG in deploy/.env"
fi

echo "== switch-pool-27b complete =="
echo "Coordinator: ${WANT_CODE27_URL} (deploy via operator-cluster-111.sh start-pool)."
echo "RAG: embed ${WANT_EMBED_URL} + rerank ${WANT_RERANK_URL} (both CPU on rag; orchestrator start-rag)."
echo "Picker: frontier-code + qwen3.6-27b only. LiteLLM config: litellm_config.inference.yaml"
echo "Next: orchestrator start-rag on rag, then sudo bash scripts/start.sh on hub (start-brain)."