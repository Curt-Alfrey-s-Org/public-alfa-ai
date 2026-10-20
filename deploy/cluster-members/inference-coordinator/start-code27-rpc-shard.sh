#!/usr/bin/env bash
# inference Code27: rpc-server on RTX 3050 :31357 only (CUDA index 0).
# Stops/removes stale gpu0/gpu1 containers so recreate never hits name conflicts.
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/start-code27-rpc-shard.sh
#
set -euo pipefail

REPO_DIR="${ALFA_REPO_DIR:-$HOME/alfa-ai}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
COMPOSE_FILE="$LLC/docker-compose.rpc-serverinference-code27.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: missing $COMPOSE_FILE (git pull or scp from orchestrator/apps)" >&2
  exit 1
fi

if ! docker image inspect alfa-llamacpp-rpc:cuda128 >/dev/null 2>&1; then
  echo "ERROR: alfa-llamacpp-rpc:cuda128 missing -- docker load b8552 hub tarball first" >&2
  exit 1
fi

echo "== inference Code27: stop 3060 shard and stale rpc containers =="
docker stop llamacpp-rpc-148-gpu0 2>/dev/null || true
docker rm -f llamacpp-rpc-148-gpu0 llamacpp-rpc-148-gpu1 2>/dev/null || true

if [[ -f "$LLC/.env.rpc" ]]; then
  (cd "$LLC" && docker compose -f docker-compose.rpc-serverinference-code27.yml --env-file .env.rpc down --remove-orphans 2>/dev/null) || true
else
  (cd "$LLC" && docker compose -f docker-compose.rpc-serverinference-code27.yml down --remove-orphans 2>/dev/null) || true
fi
mkdir -p "$LLC/rpc-cache-148"

echo "== inference Code27: start rpc-server on RTX 3050 :31357 =="
if [[ -f "$LLC/.env.rpc" ]]; then
  (cd "$LLC" && docker compose -f docker-compose.rpc-serverinference-code27.yml --env-file .env.rpc up -d --no-build --force-recreate --remove-orphans)
else
  (cd "$LLC" && docker compose -f docker-compose.rpc-serverinference-code27.yml up -d --no-build --force-recreate --remove-orphans)
fi

sleep 2
if command -v nc >/dev/null 2>&1; then
  nc -zv 127.0.0.1 31357
fi
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv
docker logs llamacpp-rpc-148-gpu1 2>&1 | head -5
