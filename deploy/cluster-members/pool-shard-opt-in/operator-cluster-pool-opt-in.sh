#!/usr/bin/env bash
# VM100 operator entry. RAG (embed + rerank) retired from this host — production
# RAG is CPU on rag (docs/RAG_148_TO_110_MIGRATION.md). VM100's GTX 1660 Super is
# a inference rpc-server shard only (:31354).
#
#   bash deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh start-shard
#   bash deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh stop-shard
#   bash deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh status
#
# Legacy (pre-migration RAG on 1660S, rollback only; start-* need ALLOW_LEGACY_VM100_RAG=1):
#   start-rag / stop-rag / start-embed / stop-embed
# Brain + DB live on hub — not on VM100.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

usage() {
  sed -n '1,14p' "$0" | tail -n +2
  exit 1
}

pull_repo() {
  if [[ "${SKIP_PULL:-0}" == "1" ]]; then
    return 0
  fi
  [[ -d "$REPO_DIR/.git" ]] || { echo "ERROR: not a git repo: $REPO_DIR" >&2; exit 1; }
  cd "$REPO_DIR"
  git pull --ff-only origin main
}

cmd_start_rag() {
  pull_repo
  bash "$SCRIPT_DIR/deploy-rag.sh"
}

cmd_stop_rag() {
  cd "$SCRIPT_DIR"
  docker compose --env-file .env.embed -f docker-compose.reranker.yml down --remove-orphans 2>/dev/null || true
  docker compose --env-file .env.embed -f docker-compose.embed-gpu.yml down --remove-orphans 2>/dev/null || true
  docker stop alfa-ai-reranker alfa-ai-embed-ollama 2>/dev/null || true
  docker rm -f alfa-ai-reranker alfa-ai-embed-ollama 2>/dev/null || true
  echo "== operator-cluster-100 stop-rag complete =="
}

cmd_start_embed() {
  pull_repo
  bash "$SCRIPT_DIR/deploy-embed.sh"
}

cmd_stop_embed() {
  cd "$SCRIPT_DIR"
  docker compose --env-file .env.embed -f docker-compose.embed-gpu.yml down
  echo "== operator-cluster-100 stop-embed complete =="
}

cmd_start_shard() {
  pull_repo
  bash "$SCRIPT_DIR/deploy-grev27-pool-shard.sh"
}

cmd_stop_shard() {
  cd "$REPO_DIR/deploy/llamacpp-rpc"
  docker compose -f docker-compose.rpc-serverpool-opt-in-gpu1660s.yml down --remove-orphans 2>/dev/null || true
  docker stop llamacpp-rpc-100-gpu1660s 2>/dev/null || true
  docker rm -f llamacpp-rpc-100-gpu1660s 2>/dev/null || true
  echo "== operator-cluster-100 stop-shard complete =="
}

cmd_status() {
  docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}' \
    | grep -E 'alfa-ai-embed|alfa-ai-reranker|llamacpp-rpc-100|NAME' || true
}

case "${1:-}" in
  start-shard) cmd_start_shard ;;
  stop-shard)  cmd_stop_shard ;;
  start-rag)   cmd_start_rag ;;
  stop-rag)    cmd_stop_rag ;;
  start-embed) cmd_start_embed ;;
  stop-embed)  cmd_stop_embed ;;
  status)      cmd_status ;;
  start-brain|stop)
    echo "ERROR: brain runs on hub; use start-shard / stop-shard" >&2
    exit 1
    ;;
  *) usage ;;
esac