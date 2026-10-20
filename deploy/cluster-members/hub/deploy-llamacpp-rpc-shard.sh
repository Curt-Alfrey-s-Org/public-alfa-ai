#!/usr/bin/env bash
# hub hub — llama.cpp rpc-server on RTX 3050 (:31353).
# Hub GGUF lives under /mnt/hub/alfa-ai/llama-cpp/models (no bind needed for rpc-server).
#
# Prerequisites: Petals worker stopped (single RTX 3050 on hub — GPU mutual exclusion).
#
# Usage (SSH as operator with docker + nvidia):
#   sudo bash deploy/cluster-members/hub/deploy-llamacpp-rpc-shard.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"

if [[ ! -d "$LLC" ]]; then
  echo "ERROR: missing $LLC" >&2
  exit 1
fi

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_common" && pwd)"
sudo bash "$COMMON/preflight-docker-engine.sh"
# Vendor sync only on cold path (image missing). inference uses prebuilt image.
if ! sudo docker image inspect alfa-llamacpp-rpc:cuda128 >/dev/null 2>&1 \
  || [[ "${FORCE_HUB_RPC_LOAD:-}" == "1" ]]; then
  sudo bash "$COMMON/sync-llamacpp-vendor-from-hub.sh" "$REPO_DIR" || true
fi
sudo FORCE_HUB_RPC_LOAD="${FORCE_HUB_RPC_LOAD:-}" bash "$COMMON/load-llamacpp-rpc-from-hub.sh"

COMPOSE_SHARD_PROJECT="${ALFA_RPC_SHARD_COMPOSE_PROJECT:-alfa-grev27-shard}"

cd "$LLC"
echo "== hub rpc-server :31353 (RTX 3050 tail shard) =="
sudo docker stop llamacpp-rpc-server llamacpp-rpc-111-gpu3050 2>/dev/null || true
sudo docker rm -f llamacpp-rpc-server llamacpp-rpc-111-gpu3050 2>/dev/null || true
sudo docker compose -p "$COMPOSE_SHARD_PROJECT" \
  -f docker-compose.rpc-serverhub-gpu3050.yml \
  down --remove-orphans 2>/dev/null || true
sudo docker compose -p "$COMPOSE_SHARD_PROJECT" \
  -f docker-compose.rpc-serverhub-gpu3050.yml \
  up -d --no-build --force-recreate

RPC_PORT=31353
bash "$COMMON/wait-inference-shard-tcp.sh" 127.0.0.1 "$RPC_PORT" 120
bash "$COMMON/wait-inference-shard-tcp.sh" hub "$RPC_PORT" 60
bash "$COMMON/assert-rpc-server-cuda.sh" llamacpp-rpc-111-gpu3050

echo "== rpc-server compose up complete =="