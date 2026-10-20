#!/usr/bin/env bash
# ALFa AI — stop the Docker Compose stack (rankings-bot–style).
#
# Usage:
#   ./scripts/stop.sh              # down brain app services (volumes preserved). DB stacks are separate.
#   ./scripts/stop.sh --app-only   # stop API, worker, LiteLLM, nginx (recommended for cluster ops)
#   ./scripts/stop.sh --deps-only  # (legacy) no-op for DBs; they live in dedicated protected stacks now
#   ./scripts/stop.sh --help
#
# DB projects (postgres/redis stacks declared in stacks.*.yml) are managed separately
# and MUST NEVER be downed by cluster stop paths. Use dedicated compose files or
# Dockge to manage them. Volumes are retained; cluster stop uses --app-only semantics
# or the brain-only compose down (which no longer includes DB services).
#
# Doc refs: docs/START_STOP_AND_OPERATIONS.md, CLUSTER_START_STOP_OPERATOR.md,
# DOCKGE_111_OPERATOR.md, DOT105_SHARED_DATA_PLANE.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_alfa_compose_env.sh"

APP_ONLY=""
DEPS_ONLY=""

for arg in "$@"; do
  case "$arg" in
    --app-only) APP_ONLY=1 ;;
    --deps-only) DEPS_ONLY=1 ;;
    -h|--help)
      sed -n '1,15p' "$0" | tail -n +2
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

cd "$ALFA_AI_DEPLOY_DIR"

if [[ -n "$DEPS_ONLY" ]]; then
  echo "DEPS_ONLY is legacy: Postgres/Redis are now dedicated protected stacks."
  echo "Use the 'postgres'/'redis' stacks (docker-compose.postgres.yml / redis.yml) or Dockge."
  echo "This script does not own or stop the dedicated DB containers."
  exit 0
fi

if [[ -n "$APP_ONLY" ]]; then
  echo "Stopping application containers (app-only; dedicated DB stacks untouched)..."
  "${ALFA_AI_COMPOSE[@]}" "${ALFA_AI_COMPOSE_ARGS[@]}" stop -t 10 \
    alfa-ai-nginx alfa-ai-worker alfa-ai-api alfa-ai-litellm 2>/dev/null || true
  echo "✅ Application stopped (dedicated Postgres/Redis stacks untouched)."
  exit 0
fi

# Unconditional path for plain stop.sh: brain compose no longer defines DB services,
# so this downs only app services. DB stacks are protected and untouched.
echo "Stopping ALFa AI brain stack (DBs are in dedicated protected stacks — not touched)..."
"${ALFA_AI_COMPOSE[@]}" "${ALFA_AI_COMPOSE_ARGS[@]}" down --remove-orphans -t 15 || true
echo "✅ Brain stack stopped (named volumes retained — data not deleted)."
echo "   Dedicated postgres/redis stacks remain up. Use --app-only explicitly in cluster wrappers."
