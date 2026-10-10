#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW_IN_USE=0
ENV_ARGS=()
for a in "$@"; do
  if [[ "$a" == "--allow-in-use" ]]; then
    ALLOW_IN_USE=1
  else
    ENV_ARGS+=("$a")
  fi
done
ENV_FILE="${ENV_ARGS[0]:-$ROOT_DIR/deploy/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  echo "Create it from deploy/.env first (gitignored on each host)."
  exit 1
fi

NGINX_CONF="$ROOT_DIR/deploy/nginx/conf.d/default.conf"
if [[ -e "$NGINX_CONF" ]] && [[ ! -f "$NGINX_CONF" ]]; then
  echo "ERROR: $NGINX_CONF is not a regular file (usually a directory)."
  echo "Remove it and restore from the alfa-ai repo, then retry:"
  echo "  rm -rf \"$NGINX_CONF\""
  echo "  git checkout HEAD -- deploy/nginx/conf.d/default.conf"
  exit 1
fi
if [[ ! -f "$NGINX_CONF" ]]; then
  echo "ERROR: Missing $NGINX_CONF — required for alfa-ai-nginx in deploy/docker-compose.yml."
  echo "Copy deploy/nginx/conf.d/default.conf from the repository before docker compose up."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

API_PORT="${ALFA_AI_API_HOST_PORT:-8412}"
PG_PORT="${ALFA_AI_POSTGRES_HOST_PORT:-5540}"
REDIS_PORT="${ALFA_AI_REDIS_HOST_PORT:-6390}"
NGINX_PORT="${ALFA_AI_NGINX_HOST_PORT:-8090}"
LITELLM_PORT="${ALFA_AI_LITELLM_HOST_PORT:-8413}"
OPERATOR_PORT="${ALFA_AI_OPERATOR_CONSOLE_HOST_PORT:-8420}"

declare -a PORTS=("$API_PORT" "$PG_PORT" "$REDIS_PORT" "$NGINX_PORT" "$LITELLM_PORT" "$OPERATOR_PORT")
declare -A LABELS=(
  ["$API_PORT"]="ALFA_AI_API_HOST_PORT"
  ["$PG_PORT"]="ALFA_AI_POSTGRES_HOST_PORT"
  ["$REDIS_PORT"]="ALFA_AI_REDIS_HOST_PORT"
  ["$NGINX_PORT"]="ALFA_AI_NGINX_HOST_PORT"
  ["$LITELLM_PORT"]="ALFA_AI_LITELLM_HOST_PORT"
  ["$OPERATOR_PORT"]="ALFA_AI_OPERATOR_CONSOLE_HOST_PORT"
)

reserved_ports=(5000 8002 8003 8004 8005 8011)

echo "Checking ALFa AI host port assignments..."
echo "  API:      $API_PORT"
echo "  PG:       $PG_PORT"
echo "  Redis:    $REDIS_PORT"
echo "  Nginx:    $NGINX_PORT"
echo "  LiteLLM:  $LITELLM_PORT"
echo "  Operator: $OPERATOR_PORT (LAN; same API as container 8000)"

for rp in "${reserved_ports[@]}"; do
  for p in "${PORTS[@]}"; do
    if [[ "$p" == "$rp" ]]; then
      echo "ERROR: ${LABELS[$p]} uses reserved port $p"
      echo "Reserved by workspace standards (rankings-bot source-of-truth)."
      exit 1
    fi
  done
done

check_port() {
  local port="$1"
  if ss -ltnH "( sport = :$port )" | awk '{print $4}' | awk -F: -v p="$port" '$NF == p {found=1} END {exit !found}'; then
    echo "ERROR: Port $port is already in use."
    return 1
  fi
  return 0
}

if [[ "$ALLOW_IN_USE" -eq 1 ]]; then
  echo "  (--allow-in-use: skipping 'port must be free' checks; use for redeploy / stack already listening)"
else
  for p in "${PORTS[@]}"; do
    check_port "$p"
  done
fi

echo "Port preflight passed."
