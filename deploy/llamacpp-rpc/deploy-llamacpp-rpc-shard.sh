#!/usr/bin/env bash
# apps GTX 1660 Super 6 GB -- llama.cpp rpc-server for Code27 pool (:31354).
# Offloads tensor/KV from inference RTX 3050 (:31357). Hub image b8552 required.
#
# Prerequisites:
#   - NFS /mnt/cluster mounted (hub docker-images + optional GGUF tree)
#   - petals-worker stopped if it uses the 1660S (GPU mutual exclusion)
#   - deploy/llamacpp-rpc/.env.rpc from env.rpc.example (RPC_PORT=31354)
#
# Usage (on apps as ansible):
#   bash deploy/cluster-members/apps/deploy-llamacpp-rpc-shard.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/home/operator/alfa-ai}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
ENV_RPC="$LLC/.env.rpc"
IMAGE='alfa-llamacpp-rpc:cuda128'
TARBALL='alfa-llamacpp-rpc-cuda128-b10355.tar.gz'

if [[ ! -d "$LLC" ]]; then
  echo "ERROR: missing $LLC" >&2
  exit 1
fi
bash "$REPO_DIR/deploy/cluster-members/_common/preflight-nfs-hub.sh"
if [[ ! -f "$ENV_RPC" ]]; then
  echo "ERROR: missing $ENV_RPC" >&2
  echo "  cp $SCRIPT_DIR/env.rpc.example $ENV_RPC" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker not reachable" >&2
  exit 1
fi
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found" >&2
  exit 1
fi

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^petals-worker$'; then
  echo "WARN: petals-worker is running -- stopping to free GTX 1660S for rpc-server..."
  docker stop petals-worker || true
fi

COMMON="$(cd "$SCRIPT_DIR/../_common" && pwd)"
bash "$COMMON/sync-llamacpp-vendor-from-hub.sh" "$REPO_DIR" || true

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  loaded=0
  for hub_root in \
    /mnt/cluster/docker-images \
    /mnt/cluster/docker/images \
    /mnt/hub/alfa-ai/docker-images; do
    tb="$hub_root/$TARBALL"
    if [[ -f "$tb" ]]; then
      echo "== docker load: $tb =="
      docker load -i "$tb"
      loaded=1
      break
    fi
  done
  if [[ "$loaded" -ne 1 ]]; then
    echo "ERROR: $IMAGE missing and $TARBALL not found under /mnt/cluster/docker-images" >&2
    exit 1
  fi
fi

cd "$LLC"
echo "== apps rpc-server :31354 (1660S Code27 helper) =="
docker stop llamacpp-rpc-server 2>/dev/null || true
docker rm -f llamacpp-rpc-server 2>/dev/null || true
docker compose --env-file .env.rpc -f docker-compose.rpc-server.yml -f docker-compose.rpc-server.cache.yml down --remove-orphans 2>/dev/null || true
docker compose --env-file .env.rpc -f docker-compose.rpc-server.yml -f docker-compose.rpc-server.cache.yml up -d --no-build --force-recreate --remove-orphans

if command -v nc >/dev/null 2>&1; then
  for _ in $(seq 1 30); do
    if nc -z 127.0.0.1 31354 2>/dev/null; then
      echo "rpc-server listening on :31354"
      exit 0
    fi
    sleep 2
  done
  echo "WARN: :31354 not accepting TCP yet -- check: docker logs llamacpp-rpc-server" >&2
  exit 1
fi

echo "== rpc-server compose up complete (install nc for port poll) =="
