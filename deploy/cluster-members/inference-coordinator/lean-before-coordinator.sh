#!/usr/bin/env bash
# Free RAM on inference before 27B CPU coordinator load (keeps rpc-server shards :31356/:31357).
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/lean-before-coordinator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

echo "== lean-before-coordinator: $(hostname -s) =="
echo "-- RAM before --"
free -h || true

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet ollama 2>/dev/null; then
    echo "Stopping ollama systemd unit..."
    sudo systemctl stop ollama || true
  fi
fi

dc() {
  if docker info >/dev/null 2>&1; then docker "$@"
  elif sudo docker info >/dev/null 2>&1; then sudo docker "$@"
  else return 0
  fi
}

# Stop retired local coordinators and inference rerank (3050 moved to hub).
for name in alfa-ai-reranker llamacpp-server-148-local llamacpp-server-148-preflight-gpu1; do
  dc stop "$name" 2>/dev/null || true
  dc rm -f "$name" 2>/dev/null || true
done

echo "-- RAM after --"
free -h || true
echo "lean-before-coordinator done"
