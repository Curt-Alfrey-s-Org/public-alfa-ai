#!/usr/bin/env bash
# Recreate brain postgres/redis with loopback + LAN dual bind for remote agent workers.
# Loopback (127.0.0.1) keeps host-network exporters healthy; LAN bind serves gaming-c/gaming-b/gaming-a workers.
set -euo pipefail

REPO="${REPO_ROOT:-/mnt/hub/alfa-ai/repo/alfa-ai}"
DEPLOY="${REPO}/deploy"
ENV="${ALFA_AI_ENV_FILE:-${DEPLOY}/.env}"

if [[ ! -f "${ENV}" ]]; then
  echo "ERROR: missing ${ENV}" >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a
source "${ENV}"
set +a

export ALFA_POSTGRES_PASSWORD="change-me"
if [[ -z "${ALFA_POSTGRES_PASSWORD}" ]]; then
  echo "ERROR: set POSTGRES_PASSWORD or ALFA_POSTGRES_PASSWORD in ${ENV}" >&2
  exit 1
fi

export ALFA_AI_POSTGRES_LAN_BIND="${ALFA_AI_POSTGRES_LAN_BIND:-hub}"
export ALFA_AI_REDIS_LAN_BIND="${ALFA_AI_REDIS_LAN_BIND:-hub}"
export ALFA_SHARED_DOCKER_NETWORK="${ALFA_SHARED_DOCKER_NETWORK:-alfa-ai-network}"

# shellcheck source=scripts/_brain_db_compose_args.sh
source "${REPO}/scripts/_brain_db_compose_args.sh"

cd "${DEPLOY}"
sudo -E docker compose --env-file "${ENV}" "${POSTGRES_COMPOSE_ARGS[@]}" up -d --force-recreate
sudo -E docker compose --env-file "${ENV}" "${REDIS_COMPOSE_ARGS[@]}" up -d --force-recreate

echo "postgres binds:"
sudo docker port alfa-postgres 5432 || true
echo "redis binds:"
sudo docker port alfa-redis 6379 || true
echo "open_lan_db_for_workers OK"
