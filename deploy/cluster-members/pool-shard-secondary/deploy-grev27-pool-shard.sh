#!/usr/bin/env bash
# gpu-248 -- deploy inference rpc-server shard on GTX 1070 (:31355).
#
# Pascal sm_61 image: alfa-llamacpp-rpc:cuda128-pascal (hub only).
# See docs/DOCKGE_248_OPERATOR.md.
#
# Usage (on secondary, operator@orchestrator):
#   bash deploy/cluster-members/pool-shard-secondary/deploy-grev27-pool-shard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

if [[ ! -d "$LLC" ]]; then
  echo "ERROR: missing $LLC" >&2
  exit 1
fi

bash "$COMMON/preflight-docker-engine.sh"

export ALFA_RPC_IMAGE_CACHE="${ALFA_RPC_IMAGE_CACHE:-${HOME}/alfa-ai-cache/docker-images}"
mkdir -p "$ALFA_RPC_IMAGE_CACHE"

inference_STOP_MODE=shard HOST_LABEL=248 bash "$COMMON/inference-stop-local.sh"
HOST_LABEL=248 bash "$COMMON/preflight-gpu-empty.sh"
bash "$COMMON/load-llamacpp-rpc-pascal-from-hub.sh"

cd "$LLC"
docker compose -f docker-compose.rpc-serversecondary-gpu1070.yml up -d --no-build --force-recreate

ok=0
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 31355 2>/dev/null; then
    ok=1
    break
  fi
  sleep 2
done
if [[ "$ok" -ne 1 ]]; then
  echo "ERROR: :31355 not listening" >&2
  exit 1
fi
echo "  OK :31355 listening"

bash "$COMMON/assert-rpc-server-cuda.sh" llamacpp-rpc-248-gpu1070
echo "deploy-grev27-pool-shard OK on gpu-248 (GTX 1070 :31355)"
echo "NOTE: join live RPC_BACKENDS via full Start-Stop-AlfaAi.ps1 stop/start from orchestrator."
