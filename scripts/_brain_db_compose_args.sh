#!/usr/bin/env bash
# Emit docker compose -f args for brain postgres/redis stacks.
# Loopback bind is always in the base compose; LAN bind is an optional merge file.
#
# Usage (after sourcing deploy/.env):
#   source scripts/_brain_db_compose_args.sh
#   docker compose "${POSTGRES_COMPOSE_ARGS[@]}" up -d
set -euo pipefail

_brain_db_lan_enabled() {
  local bind_var="$1"
  local bind_val="${!bind_var:-}"
  [[ -n "$bind_val" && "$bind_val" != "127.0.0.1" ]]
}

POSTGRES_COMPOSE_ARGS=(
  -f docker-compose.postgres.yml
)
REDIS_COMPOSE_ARGS=(
  -f docker-compose.redis.yml
)

if _brain_db_lan_enabled ALFA_AI_POSTGRES_LAN_BIND; then
  POSTGRES_COMPOSE_ARGS+=(-f docker-compose.postgres.lan-bind.yml)
fi
if _brain_db_lan_enabled ALFA_AI_REDIS_LAN_BIND; then
  REDIS_COMPOSE_ARGS+=(-f docker-compose.redis.lan-bind.yml)
fi
