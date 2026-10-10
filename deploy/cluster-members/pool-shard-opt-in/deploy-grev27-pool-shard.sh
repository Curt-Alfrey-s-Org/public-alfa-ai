#!/usr/bin/env bash
# VM100 -- deploy inference rpc-server shard on GTX 1660 Super (:31354).
#
# RAG (embed + rerank) retired from VM100 -- see .cursor/plans/RAG_248_VM100_SHARD.md.
# Run operator-cluster-100.sh stop-rag first if the old embed/rerank sidecars
# are still up (mutual exclusion on the single 1660 Super).
#
# Usage (on VM100, operator@orchestrator):
#   bash deploy/cluster-members/pool-shard-opt-in/deploy-grev27-pool-shard.sh
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

echo "== stop VM100 legacy RAG (embed + rerank) if still running =="
docker stop alfa-ai-embed-ollama alfa-ai-reranker 2>/dev/null || true
docker rm -f alfa-ai-embed-ollama alfa-ai-reranker 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/docker-compose.embed-gpu.yml" ]]; then
  (cd "$SCRIPT_DIR" && docker compose -f docker-compose.embed-gpu.yml down --remove-orphans 2>/dev/null) || true
fi
if [[ -f "$SCRIPT_DIR/docker-compose.reranker.yml" ]]; then
  (cd "$SCRIPT_DIR" && docker compose -f docker-compose.reranker.yml down --remove-orphans 2>/dev/null) || true
fi

# Same order as inference/hub: stop existing shard before GPU-empty preflight.
# Ordered recovery redeploys while the old rpc-server still holds ~2 GiB VRAM;
# without this stop, preflight fails: "GPU 0: 2156 MiB used (max 512)".
inference_STOP_MODE=shard HOST_LABEL=100 bash "$COMMON/inference-stop-local.sh"
HOST_LABEL=100 bash "$COMMON/preflight-gpu-empty.sh"
bash "$COMMON/load-llamacpp-rpc-from-hub.sh"

cd "$LLC"
docker compose -f docker-compose.rpc-serverpool-opt-in-gpu1660s.yml up -d --no-build --force-recreate

ok=0
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 31354 2>/dev/null; then
    ok=1
    break
  fi
  sleep 2
done
if [[ "$ok" -ne 1 ]]; then
  echo "ERROR: :31354 not listening" >&2
  exit 1
fi
echo "  OK :31354 listening"

bash "$COMMON/assert-rpc-server-cuda.sh" llamacpp-rpc-100-gpu1660s
echo "deploy-grev27-pool-shard OK on VM100 (1660 Super :31354)"
echo "NOTE: not yet wired into the live coordinator RPC_BACKENDS. Add to"
echo "  deploy/llamacpp-rpc/inference-shards.env, regenerate .env.rpc on hub"
echo "  (write-grev27-pool-env.sh), then run one full Start-Stop-AlfaAi.ps1"
echo "  stop/start cycle from orchestrator to pick it up -- no piecemeal coordinator touch."
