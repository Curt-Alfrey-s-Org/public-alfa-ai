#!/usr/bin/env bash
# Enable Pool72 online research missions on hub (SearXNG + agent env + redeploy).
#
# Not MCP -- uses Missions agent loop + web_search (docs/AGENT_RESEARCH_TOOLS.md).
#
# Usage (From hub as operator):
#   cd /mnt/hub/alfa-ai/repo/alfa-ai
#   bash scripts/operator-pool72-research-enable.sh
#
#   sudo bash scripts/operator-pool72-research-enable.sh   # docker via sudo; git as SUDO_USER
#
# Flags:
#   --skip-pull       Pass through to brain_redeploy_missions (default: pull)
#   --skip-searxng    Skip SearXNG compose up + host smoke
#   --skip-env        Do not patch deploy/.env
#   --skip-redeploy   Patch env + SearXNG only; no API/worker recreate
#
# Official: SearXNG Docker https://docs.searxng.org/admin/installation-docker.html
# Compose external networks https://docs.docker.com/compose/how-tos/networking/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ALFA_AI_ENV_FILE:-$REPO_ROOT/deploy/.env}"
SEARXNG_DIR="$REPO_ROOT/deploy/searxng"

DO_PULL=1
DO_SEARXNG=1
DO_ENV=1
DO_REDEPLOY=1

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
    --skip-pull) DO_PULL=0 ;;
    --skip-searxng) DO_SEARXNG=0 ;;
    --skip-env) DO_ENV=0 ;;
    --skip-redeploy) DO_REDEPLOY=0 ;;
    *)
      echo "Unknown flag: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

_set_env_kv() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sudo sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" | sudo tee -a "$ENV_FILE" >/dev/null
  fi
}

run_as_clone_owner() {
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    sudo -u "$SUDO_USER" -H "$@"
  else
    "$@"
  fi
}

echo "== operator-pool72-research-enable: start =="
echo "repo=$REPO_ROOT"
echo "env=$ENV_FILE"

if [[ "$DO_PULL" -eq 1 ]]; then
  echo "[1/5] git pull --ff-only origin main"
  (
    cd "$REPO_ROOT"
    run_as_clone_owner git pull --ff-only origin main
  )
else
  echo "[1/5] git pull skipped"
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/_alfa_compose_env.sh"

if [[ "$DO_SEARXNG" -eq 1 ]]; then
  echo "[2/5] SearXNG network + compose up"
  alfa_ensure_searxng_network || exit 1
  if [[ ! -f "$SEARXNG_DIR/docker-compose.yml" ]]; then
    echo "ERROR: missing $SEARXNG_DIR/docker-compose.yml" >&2
    exit 1
  fi
  (cd "$SEARXNG_DIR" && alfa_run_compose up -d)
  echo "[2/5] SearXNG host smoke (loopback :8888)"
  curl -fsS 'http://127.0.0.1:8888/search?q=fastapi&format=json' | head -c 400
  echo ""
else
  echo "[2/5] SearXNG skipped"
fi

if [[ "$DO_ENV" -eq 1 ]]; then
  echo "[3/6] patch deploy/.env for Pool72 research"
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: missing $ENV_FILE -- copy from deploy/env.example" >&2
    exit 1
  fi
  _set_env_kv ALFA_AI_AGENT_MODEL frontier
  _set_env_kv ALFA_AI_WEB_SEARCH_ENABLED 1
  _set_env_kv ALFA_AI_SEARXNG_URL 'http://alfa-searxng:8080'
  echo "  ALFA_AI_AGENT_MODEL=frontier"
  echo "  ALFA_AI_WEB_SEARCH_ENABLED=1"
  echo "  ALFA_AI_SEARXNG_URL=http://alfa-searxng:8080"
else
  echo "[3/6] deploy/.env patch skipped"
fi

echo "[4/6] ensure runtime schema (runs/tasks tables)"
bash "$SCRIPT_DIR/ensure-runtime-schema.sh"

if [[ "$DO_REDEPLOY" -eq 1 ]]; then
  echo "[5/6] brain_redeploy_missions (API + worker)"
  if [[ "$DO_PULL" -eq 1 ]]; then
    bash "$SCRIPT_DIR/brain_redeploy_missions.sh" --skip-pull
  else
    bash "$SCRIPT_DIR/brain_redeploy_missions.sh"
  fi
else
  echo "[5/6] redeploy skipped (recreate API manually after env change)"
fi

echo "[6/6] verify (container web_search)"
bash "$SCRIPT_DIR/verify-pool72-research-smoke.sh" --skip-host-curl

echo ""
echo "== operator-pool72-research-enable: ok =="
echo "Enqueue: bash scripts/verify-pool72-research-smoke.sh --enqueue-mission"
echo "Or Ask ALFa: mission_enqueue on host 111 with research_only=true, skill=audit-repo"
echo "Watch: Admin -> Missions -> Live tool events for web_search"
