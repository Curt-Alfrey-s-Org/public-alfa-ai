#!/usr/bin/env bash
# G-rev35: deploy 35B MoE RPC pool CPU coordinator on hub (:31360).
#
# Prerequisites:
#   - All shards in deploy/llamacpp-rpc/pool35-shards.env listening
#   - Hub GGUF on hub
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/deploy-grev35-coordinator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

if [[ ! -d "$LLC" ]]; then
  echo "ERROR: missing $LLC" >&2
  exit 1
fi

sudo bash "$COMMON/preflight-docker-engine.sh"

sudo bash "$SCRIPT_DIR/write-grev35-env.sh"

sudo FORCE_HUB_RPC_LOAD="${FORCE_HUB_RPC_LOAD:-}" bash "$COMMON/load-llamacpp-rpc-from-hub.sh"

echo "== G-rev35: verify RPC shards (pool35-shards.env) =="
inference_VERIFY_RETRIES="${inference_VERIFY_RETRIES:-30}" \
  bash "$COMMON/verify-inference-shards.sh" "$LLC/pool35-shards.env"

cd "$LLC"
sudo docker stop llamacpp-server llamacpp-server-111-grev35 llamacpp-server-111-grev27-pool 2>/dev/null || true
sudo docker rm -f llamacpp-server llamacpp-server-111-grev35 llamacpp-server-111-grev27-pool 2>/dev/null || true

# shellcheck disable=SC1090
source "$LLC/.env.rpc"
# Slot cache path comes from .env.rpc (SSD fast tier by default). Only fall back
# to the HDD clone if an older .env.rpc predates SLOT_CACHE_DIR.
sudo mkdir -p "${SLOT_CACHE_DIR:-$LLC/slot-cache-111}"
LOAD_TIMEOUT="${LOAD_TIMEOUT:-900}"

echo "== G-rev35: start 35B pool CPU coordinator on hub :31360 =="
COMPOSE_COORD_PROJECT="${ALFA_RPC_COORD_COMPOSE_PROJECT:-alfa-grev35-coord}"
sudo docker compose -p "$COMPOSE_COORD_PROJECT" --env-file .env.rpc \
  -f docker-compose.rpc-main.yml \
  -f docker-compose.rpc-main.cpu-coordinator.yml \
  -f docker-compose.rpc-main.grev35-coordinator.yml \
  -f docker-compose.rpc-main.grev35-load.yml \
  up -d --no-build --force-recreate --remove-orphans

bash "$COMMON/wait-llamacpp-coordinator-health.sh" "http://127.0.0.1:${MAIN_PORT:-31360}/health" "$LOAD_TIMEOUT"
echo "G-rev35 pool coordinator OK. LiteLLM speed tier -> http://127.0.0.1:31360/v1"
