#!/usr/bin/env bash
# Idempotent /LAN contracts-bot admin edge (:8422 -> apps:8003).
#
# Canonical host: inference (same  node as alfa-ai :8420).
# Docs: docs/CONTRACTS_BOT__EDGE.md
#
# Usage:
#   bash deploy/cluster-members/_common/start-contracts-edge.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${ALFA_AI_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
DEPLOY="$REPO_ROOT/deploy"
COMMON="$SCRIPT_DIR"
WAIT="$COMMON/wait-http.sh"
COMPOSE_FILE="$DEPLOY/docker-compose.contracts-edge.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: missing $COMPOSE_FILE" >&2
  exit 1
fi

if docker info &>/dev/null; then
  DOCKER=(docker)
elif sudo -n docker info &>/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  echo "ERROR: Docker not available" >&2
  exit 1
fi

PORT="${CONTRACTS_BOT_EDGE_HOST_PORT:-8422}"

echo "== start-contracts-edge (:${PORT} -> apps) =="

"${DOCKER[@]}" network inspect tunnel_network >/dev/null 2>&1 \
  || "${DOCKER[@]}" network create tunnel_network >/dev/null

if [[ -x "$COMMON/ensure-operator-console-ufw.sh" ]]; then
  bash "$COMMON/ensure-operator-console-ufw.sh" contracts-edge || true
fi

cd "$DEPLOY"
"${DOCKER[@]}" compose -f docker-compose.contracts-edge.yml up -d --force-recreate

if [[ -x "$WAIT" ]]; then
  bash "$WAIT" "http://127.0.0.1:${PORT}/" 60 || true
else
  sleep 3
fi

echo "contracts-bot  admin: http://100.112.43.57:${PORT}/"
echo "start-contracts-edge OK"
