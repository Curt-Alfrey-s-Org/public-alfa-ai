#!/usr/bin/env bash
# VM110 operator entry — CPU RAG sidecars (embed :11435 + rerank :8360).
#
#   bash deploy/cluster-members/rag-host/operator-cluster-110.sh start-rag
#   bash deploy/cluster-members/rag-host/operator-cluster-110.sh stop-rag
#   bash deploy/cluster-members/rag-host/operator-cluster-110.sh status
#
# Production orchestrator uses this after Phase C cutover (HOST_LABEL=110).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

usage() {
  sed -n '1,10p' "$0" | tail -n +2
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
  bash "$SCRIPT_DIR/deploy-rag-cpu.sh"
}

cmd_stop_rag() {
  HOST_LABEL=110 bash "$REPO_DIR/deploy/cluster-members/_common/stop-rag-sidecars.sh"
  echo "== operator-cluster-110 stop-rag complete =="
}

cmd_status() {
  docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}' \
    | grep -E 'alfa-ai-embed|alfa-ai-reranker|NAME' || true
}

case "${1:-}" in
  start-rag) cmd_start_rag ;;
  stop-rag)  cmd_stop_rag ;;
  status)    cmd_status ;;
  *) usage ;;
esac
