#!/usr/bin/env bash
# ALFa AI — single entry point to start the Docker Compose stack (rankings-bot-style).
#
# Prerequisites: Docker + Compose; deploy/.env on this host (gitignored); external network tunnel_network
# (create once: docker network create tunnel_network).
#
# Doc refs: docs/START_STOP_AND_OPERATIONS.md; rankings-bot docs/START_STOP_RESTART.md (sibling project pattern)
#
# Usage:
#   ./scripts/start.sh                 # up brain stack (postgres, redis, litellm, api, nginx) + verify
#   ./scripts/start.sh --rebuild       # rebuild alfa-ai-api image then up brain stack
#   ./scripts/start.sh --deps-only     # Postgres + Redis only
#   ./scripts/start.sh --no-cache      # force API rebuild (implies --rebuild)
#   ./scripts/start.sh --skip-grev27   # skip 27B coordinator preflight
#   ./scripts/start.sh --help
#
# Logs: docker logs alfa-ai-api -f   (or ./scripts/tail_api_logs.sh)
# Verify: ./scripts/brain_verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_alfa_compose_env.sh"

TUNNEL_NETWORK="${TUNNEL_NETWORK:-tunnel_network}"
DEPS_ONLY=""
REBUILD=""
NO_CACHE=""
SKIP_GREV27=""

for arg in "$@"; do
  case "$arg" in
    --deps-only) DEPS_ONLY=1 ;;
    --app-only) echo "WARN: --app-only is deprecated; use ./scripts/start.sh (brain stack includes nginx)." >&2 ;;
    --rebuild) REBUILD=1 ;;
    --no-cache) NO_CACHE=1; REBUILD=1 ;;
    --skip-grev27) SKIP_GREV27=1 ;;
    -h|--help)
      sed -n '1,22p' "$0" | tail -n +2
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

cd "$ALFA_AI_APP_ROOT"

if [[ ! -f "$ALFA_AI_COMPOSE_FILE" ]]; then
  echo "ERROR: Missing $ALFA_AI_COMPOSE_FILE" >&2
  exit 1
fi

if [[ ! -f "$ALFA_AI_ENV_FILE" ]]; then
  echo "WARN: deploy/.env not found -- using compose defaults. Create deploy/.env on this host for ports and secrets."
fi

alfa_ensure_tunnel_network || exit 1
alfa_ensure_searxng_network || exit 1

COMMON_DIR="$ALFA_AI_APP_ROOT/deploy/cluster-members/_common"
if [[ -f "$COMMON_DIR/ensure-operator-console-ufw.sh" ]]; then
  bash "$COMMON_DIR/ensure-operator-console-ufw.sh" brain || true
fi

grev27_preflight() {
  [[ -n "$SKIP_GREV27" ]] && return 0
  local code27="${LLAMACPP_CODE27_URL:-http://127.0.0.1:31360/v1}"
  if [[ -f "$ALFA_AI_ENV_FILE" ]]; then
    local _p
    _p=$(grep -E '^LLAMACPP_CODE27_URL=' "$ALFA_AI_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"') || true
    [[ -n "$_p" ]] && code27="$_p"
  fi
  local health="${code27%/v1}/health"
  # Coordinator uses host network on hub; host.docker.internal is for LiteLLM in bridge only.
  health="${health//host.docker.internal/127.0.0.1}"
  echo "G-rev27 preflight: wait for coordinator ready at $health"
  echo "  (llama-server returns 503 while loading; official: tools/server/README.md)"
  bash "$COMMON_DIR/wait-llamacpp-coordinator-health.sh" "$health" 900
  echo "  27B coordinator OK"
}

if [[ -n "$DEPS_ONLY" ]]; then
  alfa_compose_stack_guard deps || exit 1
  alfa_compose_deps_up
  echo "Dependencies started."
  exit 0
fi

grev27_preflight

echo "Starting ALFa AI brain stack..."
alfa_compose_stack_guard full || exit 1

CACHE_ARGS=()
[[ -n "$NO_CACHE" ]] && CACHE_ARGS=(--no-cache)
if [[ -n "$REBUILD" ]]; then
  export ALFA_FORCE_API_BUILD=1
fi
alfa_compose_build_api_if_needed "${CACHE_ARGS[@]}"

alfa_compose_brain_up || exit 1

VERIFY_ARGS=()
[[ -n "$SKIP_GREV27" ]] && VERIFY_ARGS+=(--skip-grev27)
bash "$SCRIPT_DIR/brain_verify.sh" "${VERIFY_ARGS[@]}"
echo "ALFa AI brain stack is up (includes nginx). Logs: ./scripts/tail_api_logs.sh"
