#!/usr/bin/env bash
# ALFa AI — full rebuild and bring-up (rankings-bot full_deploy.sh analogue, scoped to this repo).
#
# - Builds Compose images (API; frontend is baked in API image per Dockerfile.api)
# - Brings up the full stack with --wait
# - Runs scripts/healthcheck.sh
#
# Does not run DB migrations automatically — apply infra/db/schema.sql or your migration process when schema changes.
#
# Usage:
#   ./scripts/full_deploy.sh
#   ./scripts/full_deploy.sh --no-cache
#   ./scripts/full_deploy.sh --rollback-on-failure   # run stop.sh if compose up fails
#
# Env: deploy/.env on this host (gitignored). BUILD_HASH optional - see scripts/docker_build_hash.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_alfa_compose_env.sh"

NO_CACHE=""
ROLLBACK=""

for arg in "$@"; do
  case "$arg" in
    --no-cache) NO_CACHE=1 ;;
    --rollback-on-failure) ROLLBACK=1 ;;
    -h|--help)
      head -n 25 "$0" | tail -n +2
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

cd "$ALFA_AI_APP_ROOT"

if [[ -f "$SCRIPT_DIR/docker_build_hash.sh" ]]; then
  export BUILD_HASH="$("$SCRIPT_DIR/docker_build_hash.sh")"
  echo "BUILD_HASH=$BUILD_HASH"
fi

echo "[full_deploy] Model config audit (committed templates)..."
python3 "$SCRIPT_DIR/audit_model_config.py" --skip-env || {
  echo "[full_deploy] ERROR: audit_model_config failed -- fix drift before deploy" >&2
  exit 1
}

CACHE_ARGS=()
[[ -n "$NO_CACHE" ]] && CACHE_ARGS=(--no-cache)

alfa_compose_stack_guard full || exit 1

echo "[full_deploy] Building alfa-ai-api..."
export ALFA_FORCE_API_BUILD=1
alfa_compose_build_api_if_needed "${CACHE_ARGS[@]}" || exit 1

echo "[full_deploy] Starting brain stack (includes nginx)..."
alfa_compose_brain_up || {
  echo "[full_deploy] ERROR: brain stack up failed"
  [[ -n "$ROLLBACK" ]] && "$SCRIPT_DIR/stop.sh" || true
  exit 1
}


echo "[full_deploy] Health verification..."
bash "$SCRIPT_DIR/brain_verify.sh"
echo "[full_deploy] Done."
