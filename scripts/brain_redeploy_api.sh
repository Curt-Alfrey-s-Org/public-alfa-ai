#!/usr/bin/env bash
# Rebuild and recreate alfa-ai-api with a consistent BUILD_HASH (avoids unknown/local drift).
#
# Default operator path on hub (operator) -- one command after GitHub has the commit:
#   cd /mnt/hub/alfa-ai/repo/alfa-ai
#   bash scripts/brain_redeploy_api.sh
#   # or: sudo bash scripts/brain_redeploy_api.sh  (docker via sudo; git as SUDO_USER)
#
# Steps:
#   1) git pull --ff-only origin main (unless --skip-pull)
#   2) audit model config + JWT secret length
#   3) preflight Docker + dedicated postgres/redis (fail fast if down)
#   4) ensure networks; build + recreate alfa-ai-api; bring up brain stack
#   5) scripts/brain_verify.sh (skip 27B if coordinator is not already up)
#   6) SSH to monitor for incident-metrics bearer refresh (WARN if BatchMode fails;
#      cluster start from orchestrator always retries after brain health)
#
# Does not require brain API/LiteLLM/nginx already running (compose up starts them).
# Does not require full cluster/inference start. Does require Docker + alfa-postgres
# + alfa-redis (protected stacks; cluster stop leaves them up).
#
# After git pull, re-execs with --skip-pull so the pulled script body runs
# (bash otherwise keeps the pre-pull script in memory).
# Bash exec: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#
# Flags:
#   --skip-pull   Do not git pull (also set by post-pull re-exec / missions wrapper)
#
# Not in this script (wrong host or different product):
#   - git commit / push (owning clone, e.g. orchestrator)
#   - Start-Stop-AlfaAi.ps1 cluster start/stop
#   - alfa-ai-worker / Missions (use scripts/brain_redeploy_missions.sh)
#
# Requires: deploy/.env, Docker daemon, running alfa-postgres + alfa-redis,
#           scripts/docker_build_hash.sh
# Compose: https://docs.docker.com/reference/cli/docker/compose/up/
# Docker running: https://docs.docker.com/engine/daemon/troubleshoot/#check-whether-docker-is-running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORIG_ARGS=("$@")

DO_PULL=1

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
    --skip-pull) DO_PULL=0 ;;
    *)
      echo "Unknown flag: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

run_as_clone_owner() {
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    sudo -u "$SUDO_USER" -H "$@"
  else
    "$@"
  fi
}

# Pull + re-exec before build so the on-disk script/body matches origin/main.
if [[ "$DO_PULL" -eq 1 && "${ALFA_REDEPLOY_API_REEXEC:-}" != "1" ]]; then
  echo "== brain_redeploy_api: pull =="
  echo "repo=$REPO_ROOT"
  echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (
    cd "$REPO_ROOT"
    run_as_clone_owner git pull --ff-only origin main
  )
  echo "[brain_redeploy_api] re-exec after pull (use on-disk script body)"
  export ALFA_REDEPLOY_API_REEXEC=1
  exec bash "$SCRIPT_DIR/brain_redeploy_api.sh" --skip-pull "${ORIG_ARGS[@]}"
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/_alfa_compose_env.sh"

export BUILD_HASH="$("$SCRIPT_DIR/docker_build_hash.sh")"
echo "BUILD_HASH=$BUILD_HASH"
if [[ "${ALFA_REDEPLOY_API_REEXEC:-}" == "1" ]]; then
  echo "[brain_redeploy_api] git pull done (pre-re-exec)"
else
  echo "[brain_redeploy_api] git pull skipped"
fi

echo "[brain_redeploy_api] audit (committed templates + deploy/.env)..."
python3 "$SCRIPT_DIR/audit_model_config.py" --env "$ALFA_AI_ENV_FILE" || {
  echo "[brain_redeploy_api] ERROR: fix audit failures before redeploy" >&2
  exit 1
}

_jwt_len="$(awk -F= '/^ALFA_AI_JWT_SECRET=/{print length($2)}' "$ALFA_AI_ENV_FILE" 2>/dev/null | tail -1)"
if [[ "${_jwt_len:-0}" -lt 16 ]]; then
  echo "[brain_redeploy_api] ERROR: ALFA_AI_JWT_SECRET is missing or too short in $ALFA_AI_ENV_FILE" >&2
  echo "  Generate: openssl rand -hex 32" >&2
  echo "  Set: ALFA_AI_JWT_SECRET=<hex> in deploy/.env (grep shows *** even when empty)" >&2
  exit 1
fi
alfa_export_brain_env_from_dotenv

alfa_ensure_tunnel_network || exit 1
alfa_ensure_searxng_network || exit 1
alfa_compose_deps_up || exit 1

echo "[brain_redeploy_api] building alfa-ai-api..."
_alfa_compose() {
  BUILD_HASH="$BUILD_HASH" DOCKER_BUILDKIT=1 alfa_run_compose "$@"
}

(cd "$ALFA_AI_DEPLOY_DIR" && _alfa_compose build alfa-ai-api)

echo "[brain_redeploy_api] recreating API; bringing up full brain stack (includes nginx)..."
(cd "$ALFA_AI_DEPLOY_DIR" && _alfa_compose up -d --force-recreate --no-build alfa-ai-api)
alfa_compose_brain_up || exit 1

echo "[brain_redeploy_api] build hash in container:"
"${ALFA_AI_DOCKER[@]}" exec alfa-ai-api cat /app/.build-hash

# 27B is optional for an API rebuild. If the coordinator is down, skip that
# verify instead of waiting (wait-llamacpp-coordinator-health.sh is for start.sh).
# One-shot /health: llama.cpp server returns 503 while loading.
VERIFY_ARGS=()
_coord_health="http://127.0.0.1:31360/health"
if curl -fsS --max-time 3 "$_coord_health" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
  echo "[brain_redeploy_api] 27B coordinator up; including in brain_verify"
else
  echo "[brain_redeploy_api] 27B coordinator not up; brain_verify --skip-grev27 (cluster start not required)"
  VERIFY_ARGS+=(--skip-grev27)
fi

bash "$SCRIPT_DIR/brain_verify.sh" "${VERIFY_ARGS[@]}" || {
  echo "[brain_redeploy_api] ERROR: brain_verify failed - refusing success exit" >&2
  exit 1
}

# Incident-metrics scrape on monitor uses a 5h admin JWT. Recreating alfa-ai-api
# invalidates the cached bearer. Cluster start from orchestrator always refreshes after
# brain health. If this host can SSH to monitor, do it now (no Prometheus restart).
# credentials_file re-read per scrape:
#   https://prometheus.io/docs/prometheus/latest/configuration/configuration/#http_config
# OpenSSH BatchMode: https://man.openbsd.org/ssh_config.5
_refresh_107_ssh="${ALFA_INCIDENT_METRICS_REFRESH_SSH:-operator@monitor}"
if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes \
    "$_refresh_107_ssh" \
    'bash /home/operator/monitoring/scripts/refresh-alfa-ai-prometheus-bearer.sh'; then
  echo "[brain_redeploy_api] incident-metrics bearer refreshed on monitor"
else
  echo "[brain_redeploy_api] WARN: could not SSH to monitor for bearer refresh (normal on hub)."
  echo "  Next cluster start from orchestrator runs it after brain health. Or from monitor:"
  echo "  cd /home/operator/monitoring && bash scripts/refresh-alfa-ai-prometheus-bearer.sh"
fi

echo "[brain_redeploy_api] Done."
