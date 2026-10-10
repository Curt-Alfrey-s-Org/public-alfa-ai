#!/usr/bin/env bash
# Stop non-essential workloads on inference to free RAM before 27B coordinator load.
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/stop-nonessential.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"

echo "== stop-nonessential: $(hostname -s) =="
echo "-- RAM before --"
free -h || true

HOST_LABEL=148 bash "$COMMON/inference-stop-local.sh"
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

for name in alfa-ai-reranker llamacpp-server-148-local llamacpp-server-148-preflight-gpu1; do
  dc stop "$name" 2>/dev/null || true
  dc rm -f "$name" 2>/dev/null || true
done

LLC="$REPO_DIR/deploy/llamacpp-rpc"
if [[ -d "$LLC" ]]; then
  (cd "$LLC" && dc compose -p alfa-grev27-coord --env-file .env.rpc \
    -f docker-compose.rpc-main.yml \
    -f docker-compose.rpc-main.cpu-coordinator.yml \
    -f docker-compose.rpc-main.grev27-pool-coordinator.yml \
    down --remove-orphans 2>/dev/null) || true
fi

echo "-- RAM after --"
free -h || true
echo "stop-nonessential done"
