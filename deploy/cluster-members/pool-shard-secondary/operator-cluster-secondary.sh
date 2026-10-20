#!/usr/bin/env bash
# gpu-248 operator entry -- inference rpc-server shard only (:31355).
#
#   bash deploy/cluster-members/pool-shard-secondary/operator-cluster-248.sh start-shard
#   bash deploy/cluster-members/pool-shard-secondary/operator-cluster-248.sh stop-shard
#   bash deploy/cluster-members/pool-shard-secondary/operator-cluster-248.sh status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

usage() {
  sed -n '1,8p' "$0" | tail -n +2
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

cmd_start_shard() {
  pull_repo
  bash "$SCRIPT_DIR/deploy-grev27-pool-shard.sh"
}

cmd_stop_shard() {
  cd "$REPO_DIR/deploy/llamacpp-rpc"
  docker compose -f docker-compose.rpc-serversecondary-gpu1070.yml down --remove-orphans 2>/dev/null || true
  docker stop llamacpp-rpc-248-gpu1070 2>/dev/null || true
  docker rm -f llamacpp-rpc-248-gpu1070 2>/dev/null || true
  echo "== operator-cluster-248 stop-shard complete =="
}

cmd_status() {
  docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}' \
    | grep -E 'llamacpp-rpc-248|NAME' || true
}

case "${1:-}" in
  start-shard) cmd_start_shard ;;
  stop-shard)  cmd_stop_shard ;;
  status)      cmd_status ;;
  *) usage ;;
esac
