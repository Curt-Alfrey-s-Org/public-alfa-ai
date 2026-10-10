#!/usr/bin/env bash
# Phase H: deploy inference RTX 3060 rpc-server shard (:31356) for 27B pool.
# CPU coordinator runs on inference :31360 (3050 idle for other workloads).
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/deploy-grev27-pool-shard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

if [[ ! -d "$LLC" ]]; then
  echo "ERROR: missing $LLC" >&2
  exit 1
fi
bash "$COMMON/preflight-docker-engine.sh"

inference_STOP_MODE=shard HOST_LABEL=148 bash "$COMMON/inference-stop-local.sh"
HOST_LABEL=148 bash "$COMMON/preflight-gpu-empty.sh"

bash "$COMMON/load-llamacpp-rpc-from-hub.sh"

cd "$LLC"
docker compose -f docker-compose.rpc-server.dual-gpu-148.yml down --remove-orphans 2>/dev/null || true
echo "== inference rpc-server :31356 (3060 only) =="
docker compose -f docker-compose.rpc-serverinference-gpu3060.yml up -d --no-build --force-recreate

for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 31356 2>/dev/null; then
    echo "  OK :31356 listening"
    bash "$COMMON/assert-rpc-server-cuda.sh" llamacpp-rpc-148-gpu3060
    echo "deploy-grev27-pool-shard OK on inference (3060 shard only)"
    exit 0
  fi
  sleep 2
done
echo "ERROR: :31356 not listening" >&2
exit 1
