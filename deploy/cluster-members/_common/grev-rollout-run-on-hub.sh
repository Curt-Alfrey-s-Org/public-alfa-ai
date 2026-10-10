#!/usr/bin/env bash
# G-rev rollout helper -- run on hub (hub as operator). One-shot after git pull.
# Fetches 35B GGUF if missing, deploys coordinator, updates LiteLLM env keys.
set -euo pipefail

REPO="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
cd "$REPO"
git pull --ff-only origin main

MODELS="/mnt/hub/alfa-ai/llama-cpp/models"
LEAD="$MODELS/Q4_K_M/Qwen3.6-35B-A3B-Q4_K_M-00001-of-00002.gguf"
if [[ ! -f "$LEAD" ]]; then
  echo "== Fetch 35B MoE GGUF on hub (hub only) =="
  cd "$REPO/deploy/llamacpp-rpc"
  PROFILE=moe35 MODELS_DIR="$MODELS" ./scripts/fetch-qwen3-coder.sh
fi

sudo bash "$REPO/deploy/cluster-members/hub/deploy-grev35-coordinator.sh"
bash "$REPO/deploy/cluster-members/_common/wait-http.sh" "http://127.0.0.1:31360/health" 900

ENV_FILE="$REPO/deploy/.env"
touch "$ENV_FILE"
grep -q '^LLAMACPP_35B_URL=' "$ENV_FILE" || echo 'LLAMACPP_35B_URL=http://orchestrator/v1' >> "$ENV_FILE"
grep -q '^LLAMACPP_CODE27_URL=' "$ENV_FILE" || echo 'LLAMACPP_CODE27_URL=http://127.0.0.1:31360/v1' >> "$ENV_FILE"

cd "$REPO/deploy"
sudo docker compose --env-file .env up -d --force-recreate alfa-ai-litellm
bash "$REPO/deploy/cluster-members/_common/wait-litellm-liveliness.sh" 120
echo "G-rev hub startup complete"
