#!/usr/bin/env bash
# Stop canonical + legacy RAG sidecars (cluster stop phase).
#
# Usage:
#   HOST_LABEL=110 bash .../stop-rag-sidecars.sh   # canonical CPU RAG
#   HOST_LABEL=148 bash .../stop-rag-sidecars.sh   # legacy inference CPU RAG (retired 2026-07-18)
#   HOST_LABEL=100 bash .../stop-rag-sidecars.sh   # legacy pool-opt-in (1660S, retired)
#   HOST_LABEL=111 bash .../stop-rag-sidecars.sh   # legacy hub sidecars
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
LABEL="${HOST_LABEL:-$(hostname -s)}"

dc() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif sudo docker info >/dev/null 2>&1; then
    sudo docker "$@"
  else
    echo "WARN: docker not reachable on $LABEL — skip" >&2
    return 0
  fi
}

stop_container() {
  local name="$1"
  dc stop "$name" 2>/dev/null || true
  dc rm -f "$name" 2>/dev/null || true
}

echo "== stop-rag-sidecars: $LABEL =="

case "$LABEL" in
  110|vm110|alfa-ai-110)
    LLC110="$REPO_DIR/deploy/cluster-members/rag-host"
    if [[ -f "$LLC110/docker-compose.embed-cpu.yml" ]]; then
      (cd "$LLC110" && dc compose -f docker-compose.embed-cpu.yml down --remove-orphans 2>/dev/null) || true
    fi
    if [[ -f "$LLC110/docker-compose.reranker-cpu.yml" ]]; then
      (cd "$LLC110" && dc compose -f docker-compose.reranker-cpu.yml down --remove-orphans 2>/dev/null) || true
    fi
    stop_container alfa-ai-embed-ollama
    stop_container alfa-ai-reranker
    ;;
  148|ai-148)
    LLC148="$REPO_DIR/deploy/cluster-members/inference-coordinator"
    if [[ -f "$LLC148/docker-compose.embed-cpu.yml" ]]; then
      (cd "$LLC148" && dc compose -f docker-compose.embed-cpu.yml down --remove-orphans 2>/dev/null) || true
    fi
    if [[ -f "$LLC148/docker-compose.reranker-cpu.yml" ]]; then
      (cd "$LLC148" && dc compose -f docker-compose.reranker-cpu.yml down --remove-orphans 2>/dev/null) || true
    fi
    stop_container alfa-ai-embed-ollama
    stop_container alfa-ai-reranker
    # Legacy inference GPU rerank (retired 2026-07-09; stop if operator never removed it).
    if [[ -f "$LLC148/docker-compose.reranker-3050.yml" ]]; then
      (cd "$LLC148" && dc compose -f docker-compose.reranker-3050.yml down --remove-orphans 2>/dev/null) || true
    fi
    ;;
  100|vm100|alfa-ai-100)
    bash "$REPO_DIR/deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh" stop-rag
    ;;
  111|hub-111)
    hub="$REPO_DIR/deploy/cluster-members/hub"
    if [[ -f "$hub/deploy-rag-sidecars.sh" ]]; then
      sudo bash "$hub/deploy-rag-sidecars.sh" stop
    else
      stop_container alfa-ai-reranker
      stop_container alfa-ai-embed-ollama
    fi
    ;;
  *)
    echo "WARN: unknown HOST_LABEL=$LABEL — stop embed/rerank containers if present" >&2
    stop_container alfa-ai-embed-ollama
    stop_container alfa-ai-reranker
    ;;
esac

echo "stop-rag-sidecars done on $LABEL"