#!/usr/bin/env bash
# Fail if a GPU llama.cpp rpc-server / llama-server container started without CUDA.
# inference GPU shards must never silently fall back to CPU (llama.cpp default).
#
# Usage:
#   bash deploy/cluster-members/_common/assert-rpc-server-cuda.sh CONTAINER [sleep_sec]
set -euo pipefail

CONTAINER="${1:?container name required}"
SLEEP_SEC="${2:-4}"

dc() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

if ! dc inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: container not found: $CONTAINER" >&2
  exit 1
fi

sleep "$SLEEP_SEC"
logs="$(dc logs "$CONTAINER" 2>&1 || true)"

if echo "$logs" | grep -q 'failed to initialize CUDA'; then
  echo "ERROR: $CONTAINER: CUDA init failed (no CPU fallback allowed for GPU shards)" >&2
  exit 1
fi

if echo "$logs" | grep -qE 'Starting RPC server|rpc-server v'; then
  if ! echo "$logs" | grep -qE 'CUDA[0-9]+:'; then
    echo "ERROR: $CONTAINER: rpc-server has no CUDA device in logs (CPU-only rejected)" >&2
    exit 1
  fi
  echo "  OK CUDA device visible in $CONTAINER rpc-server logs"
  exit 0
fi

# llama-server sidecars (rerank) log as "main:" / "load_tensors:" not "llama-server"
if echo "$logs" | grep -qE 'server is listening|load_tensors:|main: model loaded|llama_context:'; then
  if echo "$logs" | grep -qE 'offloaded .* layers to GPU|CUDA[0-9]+ model buffer size'; then
    echo "  OK GPU layers loaded in $CONTAINER"
    exit 0
  fi
  echo "ERROR: $CONTAINER: llama-server shows no GPU offload (no CPU fallback allowed)" >&2
  exit 1
fi

echo "ERROR: $CONTAINER: no CUDA service logs yet (increase sleep or check container)" >&2
exit 1
