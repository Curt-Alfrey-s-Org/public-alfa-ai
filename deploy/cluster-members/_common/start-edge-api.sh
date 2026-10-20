#!/usr/bin/env bash
# Idempotent /LAN admin login edge proxy (:8420 -> brain hub).
#
# Canonical host: inference (Jul 2026 hub migration off apps). Legacy wrapper:
#   deploy/cluster-members/_common/start-edge-api.sh
#
# Usage:
#   bash deploy/cluster-members/_common/start-edge-api.sh
#   ALFA_AI_REPO=/home/operator/alfa-ai bash deploy/cluster-members/_common/start-edge-api.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${ALFA_AI_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
DEPLOY="$REPO_ROOT/deploy"
COMMON="$SCRIPT_DIR"
WAIT="$COMMON/wait-http.sh"
COMPOSE_FILE="$DEPLOY/docker-compose.edge-api.yml"

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

PORT="${ALFA_AI_EDGE_HOST_PORT:-8420}"
ENV_APPS="$DEPLOY/.env.apps"
if [[ -f "$ENV_APPS" ]]; then
  _p=$(grep -E '^ALFA_AI_EDGE_HOST_PORT=' "$ENV_APPS" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"') || true
  [[ -n "$_p" ]] && PORT="$_p"
fi

echo "== start-edge-api (:${PORT} admin login edge) =="

"${DOCKER[@]}" network inspect tunnel_network >/dev/null 2>&1 \
  || "${DOCKER[@]}" network create tunnel_network >/dev/null

if [[ -x "$COMMON/ensure-operator-console-ufw.sh" ]]; then
  bash "$COMMON/ensure-operator-console-ufw.sh" edge || true
fi

PF="$REPO_ROOT/scripts/preflight_api_ownership.sh"
if [[ -f "$PF" ]]; then
  echo "  preflight: API ownership (edge defines alfa-ai-api container)"
  bash "$PF" compose-will-manage-api
fi

cd "$DEPLOY"
COMPOSE_ARGS=(-f docker-compose.edge-api.yml)
if [[ -f "$ENV_APPS" ]]; then
  COMPOSE_ARGS+=(--env-file "$ENV_APPS")
fi

echo "  docker compose up -d (alfa-ai-edge-api)"
"${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" up -d --remove-orphans

if [[ -x "$WAIT" ]]; then
  bash "$WAIT" "http://127.0.0.1:${PORT}/health" 120
  bash "$WAIT" "http://127.0.0.1:${PORT}/alfa-ai/login" 120
else
  curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/health" >/dev/null
fi

echo "start-edge-api OK (LAN: http://<this-host>:${PORT}/alfa-ai/login; set ALFA_EDGE__LOGIN_URL after  bind)"