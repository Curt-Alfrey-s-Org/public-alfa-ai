#!/usr/bin/env bash
# Stop local llama.cpp / GPU workloads that conflict with the unified 27B/35B RPC pool.
#
# Usage (on orchestrator WSL / pool-opt-in / apps / hub / inference):
#   bash deploy/cluster-members/_common/inference-stop-local.sh
#
# Env:
#   inference_STOP_MODE=full|shard   default full (operator stop / switch-pool prep)
#   shard: rpc-server shard only; never stop CPU/GPU coordinators (Compose project isolation)
set -euo pipefail

dc() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif sudo docker info >/dev/null 2>&1; then
    sudo docker "$@"
  else
    echo "ERROR: docker not reachable -- cannot stop inference on $(hostname -s)" >&2
    return 1
  fi
}

STOP_MODE="${inference_STOP_MODE:-full}"
SHARD_PROJECT="${ALFA_RPC_SHARD_COMPOSE_PROJECT:-alfa-grev27-shard}"

echo "== inference-stop-local ($STOP_MODE): $(hostname -s) =="

# Fail closed: silent skip left shards/VRAM up and made "half-up" pools possible.
if ! docker info >/dev/null 2>&1 && ! sudo docker info >/dev/null 2>&1; then
  echo "ERROR: docker not reachable -- cannot stop inference on $(hostname -s)" >&2
  exit 1
fi

if [[ "$STOP_MODE" == "shard" ]]; then
  for name in \
    llamacpp-rpc-server \
    llamacpp-rpc-148-gpu0 \
    llamacpp-rpc-148-gpu1 \
    llamacpp-rpc-148-gpu3060 \
    llamacpp-rpc-148-gpu5060 \
    llamacpp-rpc-148-3050 \
    llamacpp-rpc-111-gpu3050 \
    llamacpp-rpc-100-gpu1660s \
    llamacpp-rpc-248-gpu1070 \
    llamacpp-rpc-93-gpu0 \
    llamacpp-rpc-93-gpu1; do
    dc stop "$name" 2>/dev/null || true
    dc rm -f "$name" 2>/dev/null || true
  done

  LLC="${ALFA_REPO_DIR:-${ALFA_AI_REPO:-$HOME/alfa-ai}/deploy/llamacpp-rpc}"
  if [[ -d "$LLC" ]]; then
    # Deploy on Windows/WSL uses default project name = directory (llamacpp-rpc)
    # per https://docs.docker.com/compose/how-tos/project-name/ — stop must down
    # BOTH that default and ALFA_RPC_SHARD_COMPOSE_PROJECT (alfa-grev27-shard).
    for proj in "$SHARD_PROJECT" llamacpp-rpc; do
      if [[ -f "$LLC/docker-compose.rpc-server.yml" ]]; then
        (cd "$LLC" && dc compose -p "$proj" --env-file .env.rpc \
          -f docker-compose.rpc-server.yml down --remove-orphans 2>/dev/null) || true
        if [[ -f "$LLC/docker-compose.rpc-server.cache.yml" ]]; then
          (cd "$LLC" && dc compose -p "$proj" --env-file .env.rpc \
            -f docker-compose.rpc-server.yml -f docker-compose.rpc-server.cache.yml \
            down --remove-orphans 2>/dev/null) || true
        fi
        if [[ -f "$LLC/docker-compose.rpc-server.wsl-93.yml" ]]; then
          (cd "$LLC" && dc compose -p "$proj" --env-file .env.rpc \
            -f docker-compose.rpc-server.yml -f docker-compose.rpc-server.wsl-93.yml \
            down --remove-orphans 2>/dev/null) || true
        fi
      fi
      if [[ -f "$LLC/docker-compose.rpc-server.dual-gpu-93.yml" ]]; then
        (cd "$LLC" && dc compose -p "$proj" --env-file .env.rpc \
          -f docker-compose.rpc-server.dual-gpu-93.yml down --remove-orphans 2>/dev/null) || true
      fi
      if [[ -f "$LLC/docker-compose.rpc-serverinference-gpu3060.yml" ]]; then
        (cd "$LLC" && dc compose -p "$proj" \
          -f docker-compose.rpc-serverinference-gpu3060.yml down --remove-orphans 2>/dev/null) || true
      fi
      if [[ -f "$LLC/docker-compose.rpc-server.dual-gpu-148.yml" ]]; then
        (cd "$LLC" && dc compose -p "$proj" \
          -f docker-compose.rpc-server.dual-gpu-148.yml down --remove-orphans 2>/dev/null) || true
      fi
      if [[ -f "$LLC/docker-compose.rpc-serverinference-code27.yml" ]]; then
        (cd "$LLC" && dc compose -p "$proj" \
          -f docker-compose.rpc-serverinference-code27.yml down --remove-orphans 2>/dev/null) || true
      fi
      if [[ -f "$LLC/docker-compose.rpc-serverhub-gpu3050.yml" ]]; then
        (cd "$LLC" && dc compose -p "$proj" \
          -f docker-compose.rpc-serverhub-gpu3050.yml down --remove-orphans 2>/dev/null) || true
      fi
      if [[ -f "$LLC/docker-compose.rpc-serverpool-opt-in-gpu1660s.yml" ]]; then
        (cd "$LLC" && dc compose -p "$proj" \
          -f docker-compose.rpc-serverpool-opt-in-gpu1660s.yml down --remove-orphans 2>/dev/null) || true
      fi
      if [[ -f "$LLC/docker-compose.rpc-serversecondary-gpu1070.yml" ]]; then
        (cd "$LLC" && dc compose -p "$proj" \
          -f docker-compose.rpc-serversecondary-gpu1070.yml down --remove-orphans 2>/dev/null) || true
      fi
    done
  fi

  # Same leftover sweep as full mode (shard path previously skipped this).
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    cname="$(dc inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's/^\///' || true)"
    echo "Stopping leftover alfa-llamacpp-rpc container $cid (${cname:-unknown})..."
    dc stop "$cid" 2>/dev/null || true
    dc rm -f "$cid" 2>/dev/null || true
  done < <(dc ps -q --filter ancestor=alfa-llamacpp-rpc:cuda128 2>/dev/null || true)

  left="$(dc ps -q --filter ancestor=alfa-llamacpp-rpc:cuda128 2>/dev/null || true)"
  if [[ -n "$left" ]]; then
    echo "ERROR: alfa-llamacpp-rpc containers still running after shard stop:" >&2
    dc ps --filter ancestor=alfa-llamacpp-rpc:cuda128 >&2 || true
    exit 1
  fi
  if dc ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'llamacpp-rpc-server'; then
    echo "ERROR: llamacpp-rpc-server still present after shard stop" >&2
    exit 1
  fi

  echo "inference-stop-local (shard) done"
  exit 0
fi

for name in \
  llamacpp-server \
  llamacpp-server-111-grev35 \
  llamacpp-server-111-grev27-pool \
  llamacpp-server-148-grev27-pool \
  llamacpp-server-148-local \
  llamacpp-server-148-preflight-gpu1 \
  llamacpp-rpc-server \
  llamacpp-rpc-148-gpu0 \
  llamacpp-rpc-148-gpu1 \
  llamacpp-rpc-148-gpu3060 \
  llamacpp-rpc-148-gpu5060 \
  llamacpp-rpc-148-3050 \
  llamacpp-rpc-111-gpu3050 \
  llamacpp-rpc-100-gpu1660s \
  llamacpp-rpc-248-gpu1070 \
  llamacpp-rpc-93-gpu0 \
  llamacpp-rpc-93-gpu1 \
  alfa-ai-reranker \
  alfa-ai-embed-ollama; do
  dc stop "$name" 2>/dev/null || true
  dc rm -f "$name" 2>/dev/null || true
done

if dc ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^petals-worker$'; then
  echo "Stopping petals-worker (GPU mutual exclusion)..."
  dc stop petals-worker 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ollama 2>/dev/null; then
  echo "Stopping ollama..."
  sudo systemctl stop ollama || true
fi

LLC="${ALFA_REPO_DIR:-${ALFA_AI_REPO:-$HOME/alfa-ai}/deploy/llamacpp-rpc}"
if [[ -d "$LLC" ]]; then
  if [[ -f "$LLC/docker-compose.rpc-server.yml" ]]; then
    (cd "$LLC" && dc compose --env-file .env.rpc -f docker-compose.rpc-server.yml \
      -f docker-compose.rpc-server.cache.yml down --remove-orphans 2>/dev/null) || true
  fi
  if [[ -f "$LLC/docker-compose.rpc-serverinference-gpu3060.yml" ]]; then
    (cd "$LLC" && dc compose -f docker-compose.rpc-serverinference-gpu3060.yml down --remove-orphans 2>/dev/null) || true
  fi
  if [[ -f "$LLC/docker-compose.rpc-server.dual-gpu-148.yml" ]]; then
    (cd "$LLC" && dc compose -f docker-compose.rpc-server.dual-gpu-148.yml down --remove-orphans 2>/dev/null) || true
  fi
  if [[ -f "$LLC/docker-compose.rpc-serverinference-code27.yml" ]]; then
    (cd "$LLC" && dc compose -f docker-compose.rpc-serverinference-code27.yml down --remove-orphans 2>/dev/null) || true
  fi
  if [[ -f "$LLC/docker-compose.rpc-serverhub-gpu3050.yml" ]]; then
    (cd "$LLC" && dc compose -f docker-compose.rpc-serverhub-gpu3050.yml down --remove-orphans 2>/dev/null) || true
  fi
  if [[ -f "$LLC/docker-compose.rpc-serverpool-opt-in-gpu1660s.yml" ]]; then
    (cd "$LLC" && dc compose -f docker-compose.rpc-serverpool-opt-in-gpu1660s.yml down --remove-orphans 2>/dev/null) || true
  fi
  if [[ -f "$LLC/docker-compose.rpc-serversecondary-gpu1070.yml" ]]; then
    (cd "$LLC" && dc compose -f docker-compose.rpc-serversecondary-gpu1070.yml down --remove-orphans 2>/dev/null) || true
  fi
  if [[ -f "$LLC/docker-compose.rpc-server.dual-gpu-93.yml" ]]; then
    (cd "$LLC" && dc compose --env-file .env.rpc \
      -f docker-compose.rpc-server.dual-gpu-93.yml down --remove-orphans 2>/dev/null) || true
  fi
  if [[ -f "$LLC/docker-compose.rpc-main.local-dual-gpu.yml" ]]; then
    (cd "$LLC" && dc compose --env-file .env.rpc -f docker-compose.rpc-main.yml \
      -f docker-compose.rpc-main.local-dual-gpu.yml down --remove-orphans 2>/dev/null) || true
  fi
  if [[ -f "$LLC/docker-compose.rpc-main.grev27-pool-coordinator.yml" ]]; then
    (cd "$LLC" && dc compose -p alfa-grev27-coord --env-file .env.rpc \
      -f docker-compose.rpc-main.yml \
      -f docker-compose.rpc-main.cpu-coordinator.yml \
      -f docker-compose.rpc-main.grev27-pool-coordinator.yml \
      down --remove-orphans 2>/dev/null) || true
  fi
fi

# Sweep any remaining containers from the RPC image (named leftovers + random
# compose names). Previously "preserve" skipped named grev27/rpc containers, so
# a failed first stop left them running and made half-up pools possible.
for rpc_image in alfa-llamacpp-rpc:cuda128 alfa-llamacpp-rpc:cuda128-pascal; do
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    cname="$(dc inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's/^\///' || true)"
    echo "Stopping leftover $rpc_image container $cid (${cname:-unknown})..."
    dc stop "$cid" 2>/dev/null || true
    dc rm -f "$cid" 2>/dev/null || true
  done < <(dc ps -q --filter "ancestor=$rpc_image" 2>/dev/null || true)

  left="$(dc ps -q --filter "ancestor=$rpc_image" 2>/dev/null || true)"
  if [[ -n "$left" ]]; then
    echo "ERROR: $rpc_image containers still running after stop:" >&2
    dc ps --filter "ancestor=$rpc_image" >&2 || true
    exit 1
  fi
done

echo "inference-stop-local done"
