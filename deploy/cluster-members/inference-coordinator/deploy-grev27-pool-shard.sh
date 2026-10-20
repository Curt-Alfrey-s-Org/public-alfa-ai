#!/usr/bin/env bash
# Phase H: deploy inference rpc-server shards for 27B pool (:31356 3060 + :31357 5060).
# CPU coordinator runs on hub :31360.
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

echo "== stop inference legacy GPU rerank (RAG is CPU on inference; shards do not need NFS) =="
docker stop alfa-ai-reranker 2>/dev/null || true
docker rm -f alfa-ai-reranker 2>/dev/null || true

# Warm path: load-*.sh skips hub when image is present; NFS preflight only on cold load.
bash "$COMMON/load-llamacpp-rpc-from-hub.sh"

cd "$LLC"
docker compose -f docker-compose.rpc-serverinference-gpu3060.yml down --remove-orphans 2>/dev/null || true
docker compose -f docker-compose.rpc-serverinference-code27.yml down --remove-orphans 2>/dev/null || true
STAGGER="${inference_SHARD_STAGGER_SEC:-20}"
echo "== inference rpc-server :31356 (3060) then :31357 (5060), stagger ${STAGGER}s =="
docker compose -f docker-compose.rpc-server.dual-gpu-148.yml up -d --no-build --force-recreate llamacpp-rpc-148-gpu3060
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 31356 2>/dev/null; then break; fi
  sleep 2
done
echo "  OK :31356 listening; sleep ${STAGGER}s before 5060 shard"
sleep "$STAGGER"
docker compose -f docker-compose.rpc-server.dual-gpu-148.yml up -d --no-build --force-recreate llamacpp-rpc-148-gpu5060

for port in 31356 31357; do
  ok=0
  for _ in $(seq 1 30); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      ok=1
      break
    fi
    sleep 2
  done
  if [[ "$ok" -ne 1 ]]; then
    echo "ERROR: :${port} not listening" >&2
    exit 1
  fi
  echo "  OK :${port} listening"
done

bash "$COMMON/assert-rpc-server-cuda.sh" llamacpp-rpc-148-gpu3060
bash "$COMMON/assert-rpc-server-cuda.sh" llamacpp-rpc-148-gpu5060
echo "deploy-grev27-pool-shard OK on inference (3060 + 5060 shards)"