#!/usr/bin/env bash
# Shared Compose paths for ALFa AI (sourced by start.sh, stop.sh, full_deploy.sh, healthcheck.sh).
# Mirrors rankings-bot pattern: one authoritative compose project, env file for host ports/secrets.
#
# Set before source:
#   SCRIPT_DIR = directory of the calling script (scripts/)

: "${SCRIPT_DIR:?SCRIPT_DIR must be set}"

export ALFA_AI_APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export ALFA_AI_DEPLOY_DIR="$ALFA_AI_APP_ROOT/deploy"
export ALFA_AI_COMPOSE_FILE="$ALFA_AI_DEPLOY_DIR/docker-compose.yml"
export ALFA_AI_ENV_FILE="$ALFA_AI_DEPLOY_DIR/.env"

export ALFA_AI_COMPOSE_ARGS=(-f "$ALFA_AI_COMPOSE_FILE")
if [[ -f "$ALFA_AI_ENV_FILE" ]]; then
  ALFA_AI_COMPOSE_ARGS+=(--env-file "$ALFA_AI_ENV_FILE")
fi

# Export selected keys from deploy/.env so compose ${VAR} substitution and container
# environment receive the same values (env_file alone is not always enough on all hosts).
alfa_dotenv_get() {
  local key="$1"
  grep -E "^[[:space:]]*${key}=" "$ALFA_AI_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

alfa_export_brain_env_from_dotenv() {
  [[ -f "$ALFA_AI_ENV_FILE" ]] || return 0
  local jwt
  jwt="$(alfa_dotenv_get ALFA_AI_JWT_SECRET)"
  if [[ -n "$jwt" ]]; then
    export ALFA_AI_JWT_SECRET="$jwt"
  fi
}

alfa_export_brain_env_from_dotenv

# Run docker compose from deploy/ with env-file and exported brain secrets preserved under sudo.
alfa_run_compose() {
  if [[ "${ALFA_AI_DOCKER[0]:-docker}" == "sudo" ]]; then
    (
      cd "$ALFA_AI_DEPLOY_DIR" || exit 1
      sudo -E docker compose "${ALFA_AI_COMPOSE_ARGS[@]}" "$@"
    )
  else
    (
      cd "$ALFA_AI_DEPLOY_DIR" || exit 1
      docker compose "${ALFA_AI_COMPOSE_ARGS[@]}" "$@"
    )
  fi
}

if docker info &>/dev/null; then
  export ALFA_AI_DOCKER=(docker)
elif sudo -n docker info &>/dev/null 2>&1 || sudo docker info &>/dev/null; then
  export ALFA_AI_DOCKER=(sudo docker)
else
  echo "ERROR: Docker is not available (try: sudo usermod -aG docker \$USER && newgrp docker)." >&2
  exit 2
fi

if "${ALFA_AI_DOCKER[@]}" compose version &>/dev/null; then
  export ALFA_AI_COMPOSE=("${ALFA_AI_DOCKER[@]}" compose)
elif command -v docker-compose &>/dev/null; then
  export ALFA_AI_COMPOSE=(docker-compose)
else
  echo "ERROR: Docker Compose not found." >&2
  exit 2
fi

# Stable, line-oriented Compose output (aligns with professional ops: readable logs)
export COMPOSE_PROGRESS="${COMPOSE_PROGRESS:-plain}"

# Brain stack: required for website + LiteLLM (nginx included — never start separately).
# DBs (postgres/redis) are now dedicated protected stacks (not part of this brain compose).
ALFA_AI_BRAIN_SERVICES=(
  alfa-ai-litellm
  alfa-ai-api
  alfa-ai-nginx
)

# Full stack services (brain only; Petals gateway retired).
ALFA_AI_STACK_SERVICES=(
  "${ALFA_AI_BRAIN_SERVICES[@]}"
)

# Compose `up` flags: drop containers for services removed from the compose file (avoids stray one-off services).
ALFA_AI_COMPOSE_UP_FLAGS=(--remove-orphans)

# --- Stack guards: single owner per host port (Docker proxy OK); no duplicate publishers; project label sanity ---
# Note: Postgres/Redis host ports are now published by the *dedicated* stacks, not this brain compose.
# The guards still protect those ports to prevent conflicts when dedicated stacks are brought up.

alfa_expected_compose_project() {
  local name="${COMPOSE_PROJECT_NAME:-}"
  if [[ -z "$name" && -f "$ALFA_AI_ENV_FILE" ]]; then
    name=$(grep -E '^[[:space:]]*COMPOSE_PROJECT_NAME=' "$ALFA_AI_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"'"'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  fi
  # Compose file top-level `name:` (deploy/docker-compose.yml -> alfa-ai) wins over
  # the deploy/ directory basename; matches Dockge stack folder and container labels.
  if [[ -z "$name" && -f "$ALFA_AI_COMPOSE_FILE" ]]; then
    name=$(grep -E '^[[:space:]]*name:[[:space:]]*' "$ALFA_AI_COMPOSE_FILE" 2>/dev/null | head -1 | sed 's/^[[:space:]]*name:[[:space:]]*//' | tr -d '\r"'"'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  fi
  if [[ -z "$name" ]]; then
    name=$(basename "$ALFA_AI_DEPLOY_DIR")
  fi
  printf '%s' "$name"
}

alfa_load_stack_host_ports() {
  _alfa_getp() { grep -E "^$1=" "$ALFA_AI_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
  ALFA_GUARD_API_PORT="${ALFA_AI_API_HOST_PORT:-8412}"
  ALFA_GUARD_LITELLM_PORT="${ALFA_AI_LITELLM_HOST_PORT:-8413}"
  ALFA_GUARD_NGINX_PORT="${ALFA_AI_NGINX_HOST_PORT:-8090}"
  ALFA_GUARD_PG_PORT="${ALFA_AI_POSTGRES_HOST_PORT:-5540}"
  ALFA_GUARD_REDIS_PORT="${ALFA_AI_REDIS_HOST_PORT:-6390}"
  ALFA_GUARD_OP_PORT="${ALFA_AI_OPERATOR_CONSOLE_HOST_PORT:-8420}"
  if [[ -f "$ALFA_AI_ENV_FILE" ]]; then
    local _p
    _p=$(_alfa_getp ALFA_AI_API_HOST_PORT) && [[ -n "$_p" ]] && ALFA_GUARD_API_PORT="$_p"
    _p=$(_alfa_getp ALFA_AI_LITELLM_HOST_PORT) && [[ -n "$_p" ]] && ALFA_GUARD_LITELLM_PORT="$_p"
    _p=$(_alfa_getp ALFA_AI_NGINX_HOST_PORT) && [[ -n "$_p" ]] && ALFA_GUARD_NGINX_PORT="$_p"
    _p=$(_alfa_getp ALFA_AI_POSTGRES_HOST_PORT) && [[ -n "$_p" ]] && ALFA_GUARD_PG_PORT="$_p"
    _p=$(_alfa_getp ALFA_AI_REDIS_HOST_PORT) && [[ -n "$_p" ]] && ALFA_GUARD_REDIS_PORT="$_p"
    _p=$(_alfa_getp ALFA_AI_OPERATOR_CONSOLE_HOST_PORT) && [[ -n "$_p" ]] && ALFA_GUARD_OP_PORT="$_p"
  fi
}

# True if nothing is listening on port, or the listener is docker-proxy / containerd (stack redeploy OK).
alfa_port_owned_by_docker_or_free() {
  local port="$1"
  if ! command -v ss &>/dev/null; then
    return 0
  fi
  if ! ss -ltnH "( sport = :$port )" 2>/dev/null | grep -q .; then
    return 0
  fi
  local pid exe
  pid="$(ss -ltnpH "( sport = :$port )" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)" || true
  if [[ -z "$pid" ]]; then
    return 0
  fi
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  if [[ "$exe" == *docker-proxy* ]] || [[ "$exe" == *dockerd* ]] || [[ "$exe" == *containerd* ]]; then
    return 0
  fi
  echo "ERROR: Host port $port is in use by a non-Docker process (pid=$pid exe=$exe)." >&2
  echo "Stop that process or pick another port in deploy/.env — only one service may bind this port." >&2
  return 1
}

alfa_compose_guard_host_ports() {
  local mode="${1:-full}"
  alfa_load_stack_host_ports
  case "$mode" in
    deps)
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_PG_PORT" || return 1
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_REDIS_PORT" || return 1
      ;;
    app)
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_API_PORT" || return 1
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_LITELLM_PORT" || return 1
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_NGINX_PORT" || return 1
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_OP_PORT" || return 1
      ;;
    full|*)
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_API_PORT" || return 1
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_LITELLM_PORT" || return 1
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_NGINX_PORT" || return 1
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_PG_PORT" || return 1
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_REDIS_PORT" || return 1
      alfa_port_owned_by_docker_or_free "$ALFA_GUARD_OP_PORT" || return 1
      ;;
  esac
}

# Fail if more than one running container publishes the same host port (e.g. duplicate compose projects / manual runs).
alfa_compose_guard_duplicate_publishers() {
  alfa_load_stack_host_ports
  local p count
  for p in "$ALFA_GUARD_API_PORT" "$ALFA_GUARD_LITELLM_PORT" "$ALFA_GUARD_NGINX_PORT" "$ALFA_GUARD_PG_PORT" "$ALFA_GUARD_REDIS_PORT" "$ALFA_GUARD_OP_PORT"; do
    count="$("${ALFA_AI_DOCKER[@]}" ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -F ":${p}->" | wc -l)"
    count="${count// /}"
    if (( count > 1 )); then
      echo "ERROR: Multiple running containers publish host port ${p}. Expected a single listener." >&2
      echo "Inspect: docker ps --format '{{.Names}} {{.Ports}}' | grep :${p}->" >&2
      return 1
    fi
  done
}

# Warn if fixed-name containers exist under a different Compose project label (stale / second checkout using another project name).
alfa_compose_guard_project_labels() {
  local expected name proj
  expected="$(alfa_expected_compose_project)"
  # Brain stack services only (exclude alfa-ai-postgres-backup and other sibling compose files).
  local brain_containers=(
    alfa-ai-api
    alfa-ai-litellm
    alfa-ai-nginx
    alfa-ai-worker
    alfa-ai-incident-worker
  )
  for name in "${brain_containers[@]}"; do
    [[ -z "$name" ]] && continue
    if ! "${ALFA_AI_DOCKER[@]}" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      continue
    fi
    proj="$("${ALFA_AI_DOCKER[@]}" inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
    if [[ -n "$proj" && "$proj" != "$expected" ]]; then
      echo "WARN: Container $name belongs to Compose project '$proj' (this checkout expects '$expected')." >&2
      echo "      If this is stale: cd deploy && docker compose down --remove-orphans  (from that tree), or docker rm -f $name" >&2
    fi
  done
}

alfa_compose_stack_guard() {
  local mode="${1:-full}"
  echo "Compose stack guard (${mode}): host ports + duplicate publishers..."
  alfa_compose_guard_host_ports "$mode" || return 1
  alfa_compose_guard_duplicate_publishers || return 1
  alfa_compose_guard_project_labels
  echo "Compose stack guard OK."
}

# External tunnel network (shared with alfaqd / rankings on apps).
alfa_ensure_tunnel_network() {
  local net="${TUNNEL_NETWORK:-tunnel_network}"
  "${ALFA_AI_DOCKER[@]}" network inspect "$net" &>/dev/null \
    || "${ALFA_AI_DOCKER[@]}" network create "$net" 2>/dev/null \
    || { echo "ERROR: Cannot create or inspect Docker network $net" >&2; return 1; }
}

# Shared network used by dedicated DB stacks and brain consumers for DNS.
# On hub: defaults to alfa-ai-network (set ALFA_SHARED_DOCKER_NETWORK to override).
# Idempotent create (bridge). Dedicated stacks declare it external, so this pre-creates.
alfa_ensure_shared_network() {
  local net="${ALFA_SHARED_DOCKER_NETWORK:-alfa-ai-network}"
  "${ALFA_AI_DOCKER[@]}" network inspect "$net" &>/dev/null \
    || "${ALFA_AI_DOCKER[@]}" network create --driver bridge "$net" 2>/dev/null \
    || { echo "ERROR: Cannot create or inspect Docker network $net" >&2; return 1; }
}

# Shared bridge for brain API <-> SearXNG (deploy/searxng). Both compose files mark
# alfa-searxng external; create before either stack up.
# Docs: https://docs.docker.com/compose/how-tos/networking/
alfa_ensure_searxng_network() {
  local net="${ALFA_SEARXNG_DOCKER_NETWORK:-alfa-searxng}"
  "${ALFA_AI_DOCKER[@]}" network inspect "$net" &>/dev/null \
    || "${ALFA_AI_DOCKER[@]}" network create --driver bridge "$net" 2>/dev/null \
    || { echo "ERROR: Cannot create or inspect Docker network $net" >&2; return 1; }
}

# First running container name from docker ps (exact Names match).
# docker ps --format: https://docs.docker.com/reference/cli/docker/container/ls/
alfa_first_running_container() {
  local names n
  names="$("${ALFA_AI_DOCKER[@]}" ps --format '{{.Names}}' 2>/dev/null || true)"
  for n in "$@"; do
    if printf '%s\n' "$names" | grep -qx "$n"; then
      printf '%s' "$n"
      return 0
    fi
  done
  return 1
}

# Wait until compose healthcheck is healthy (or none). Fail on unhealthy/missing.
# inspect --type=container: https://docs.docker.com/reference/cli/docker/inspect/
# Health values: starting|healthy|unhealthy (compose healthcheck).
alfa_wait_container_healthy() {
  local name="$1"
  local tries="${2:-20}"
  local i health
  for i in $(seq 1 "$tries"); do
    health="$("${ALFA_AI_DOCKER[@]}" inspect --type=container \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      "$name" 2>/dev/null || echo missing)"
    case "$health" in
      healthy|none) return 0 ;;
      starting) sleep 3 ;;
      *)
        echo "ERROR: $name health=$health (want healthy). Dedicated stack must be up." >&2
        return 1
        ;;
    esac
  done
  echo "ERROR: $name still health=starting after ${tries} checks" >&2
  return 1
}

# DBs are owned by dedicated protected stacks (postgres/redis declared in stacks.*.yml).
# This does not start them. Fail fast if they are not running/healthy.
# Postgres healthcheck uses pg_isready: https://www.postgresql.org/docs/current/app-pg-isready.html
# Docker daemon: sourced above via docker info
#   https://docs.docker.com/engine/daemon/troubleshoot/#check-whether-docker-is-running
alfa_compose_deps_up() {
  local pg redis
  echo "Preflight: dedicated Postgres/Redis (not started by this script; cluster stop leaves them up)."
  pg="$(alfa_first_running_container alfa-postgres alfa-ai-postgres)" || {
    echo "ERROR: dedicated postgres is not running (need alfa-postgres or alfa-ai-postgres)." >&2
    echo "  Start Dockge stack 'postgres' on hub. Do not use cluster start for this." >&2
    echo "  Brain API/LiteLLM/nginx do not need to be running; compose up starts them." >&2
    return 1
  }
  redis="$(alfa_first_running_container alfa-redis alfa-ai-redis)" || {
    echo "ERROR: dedicated redis is not running (need alfa-redis or alfa-ai-redis)." >&2
    echo "  Start Dockge stack 'redis' on hub. Do not use cluster start for this." >&2
    return 1
  }
  alfa_wait_container_healthy "$pg" || return 1
  alfa_wait_container_healthy "$redis" || return 1
  echo "OK dedicated DBs: $pg $redis"
  return 0
}

alfa_resolve_build_hash() {
  if [[ -n "${BUILD_HASH:-}" ]]; then
    printf '%s' "$BUILD_HASH"
    return 0
  fi
  if [[ -f "$ALFA_AI_APP_ROOT/scripts/docker_build_hash.sh" ]]; then
    "$ALFA_AI_APP_ROOT/scripts/docker_build_hash.sh"
    return 0
  fi
  printf '%s' "local"
}

# Build API image only when --rebuild or image tag missing.
# Export BUILD_HASH so a later compose up uses the same tag (not alfa-ai-app:local).
# Compose interpolation: https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/
alfa_compose_build_api_if_needed() {
  local -a cache_args=()
  if [[ "${ALFA_FORCE_API_BUILD:-0}" == "1" ]]; then
    cache_args=(--no-cache)
  elif [[ $# -gt 0 ]]; then
    cache_args=("$@")
  fi
  local bh
  bh="$(alfa_resolve_build_hash)"
  export BUILD_HASH="$bh"
  local tag="alfa-ai-app:${BUILD_HASH}"
  if [[ "${ALFA_FORCE_API_BUILD:-0}" == "1" ]] \
    || ! "${ALFA_AI_DOCKER[@]}" image inspect "$tag" >/dev/null 2>&1; then
    echo "Building alfa-ai-api (${tag})..."
    BUILD_HASH="$BUILD_HASH" DOCKER_BUILDKIT=1 alfa_run_compose build "${cache_args[@]}" alfa-ai-api \
      || { echo "ERROR: alfa-ai-api build failed" >&2; return 1; }
  else
    echo "Using existing alfa-ai-api image (${tag})."
  fi
}

# Required brain services including nginx (compose depends_on waits for API healthy).
# DBs are assumed up in their dedicated stacks (started before this).
# Retry with --force-recreate when containers still reference a deleted network ID
# (official Compose: https://docs.docker.com/reference/cli/docker/compose/up/ ;
#  docker/compose#5745 — engine refuses start until containers are recreated).
alfa_compose_brain_up() {
  alfa_ensure_shared_network || return 1
  alfa_ensure_searxng_network || return 1
  if [[ -z "${BUILD_HASH:-}" ]]; then
    export BUILD_HASH
    BUILD_HASH="$(alfa_resolve_build_hash)"
  fi
  echo "Bringing up brain stack (litellm, api, nginx) image=alfa-ai-app:${BUILD_HASH}..."
  local up_log
  up_log="$(mktemp)"
  if ! BUILD_HASH="$BUILD_HASH" alfa_run_compose up -d --wait --no-build \
      "${ALFA_AI_COMPOSE_UP_FLAGS[@]}" "${ALFA_AI_BRAIN_SERVICES[@]}" \
      >"$up_log" 2>&1; then
    cat "$up_log" >&2
    if grep -qiE 'network .+ not found|failed to set up container networking' "$up_log"; then
      echo "WARN: stale Docker network attachment; retrying brain up with --force-recreate" >&2
      if BUILD_HASH="$BUILD_HASH" alfa_run_compose up -d --wait --no-build --force-recreate \
          "${ALFA_AI_COMPOSE_UP_FLAGS[@]}" "${ALFA_AI_BRAIN_SERVICES[@]}"; then
        rm -f "$up_log"
        echo "Brain stack healthy (includes alfa-ai-nginx). Dedicated DB stacks must be pre-started."
        return 0
      fi
    fi
    rm -f "$up_log"
    echo "ERROR: brain stack up failed" >&2
    return 1
  fi
  cat "$up_log"
  rm -f "$up_log"
  echo "Brain stack healthy (includes alfa-ai-nginx). Dedicated DB stacks must be pre-started."
}
