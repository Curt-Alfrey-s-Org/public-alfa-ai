#!/usr/bin/env bash
# ALFa AI — container and HTTP health checks (rankings-bot scripts/healthcheck.sh pattern).
#
# Checks: core containers running, Docker health status where defined, HTTP /health on API.
#
# Env:
#   ALFA_AI_API_HOST_PORT (default 8412) — must match deploy/.env
#   SKIP_OPTIONAL (set to 1 to skip LiteLLM / nginx HTTP checks)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_alfa_compose_env.sh"

API_PORT="${ALFA_AI_API_HOST_PORT:-8412}"
LITELLM_PORT="${ALFA_AI_LITELLM_HOST_PORT:-8413}"
NGINX_PORT="${ALFA_AI_NGINX_HOST_PORT:-8090}"
_getp() { grep -E "^$1=" "$ALFA_AI_ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"'; }
if [[ -f "$ALFA_AI_ENV_FILE" ]]; then
  _p=$(_getp ALFA_AI_API_HOST_PORT) && [[ -n "$_p" ]] && API_PORT="$_p"
  _p=$(_getp ALFA_AI_LITELLM_HOST_PORT) && [[ -n "$_p" ]] && LITELLM_PORT="$_p"
  _p=$(_getp ALFA_AI_NGINX_HOST_PORT) && [[ -n "$_p" ]] && NGINX_PORT="$_p"
fi
SKIP_OPTIONAL="${SKIP_OPTIONAL:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DOCKER=("${ALFA_AI_DOCKER[@]}")

echo "=== ALFa AI health check ==="
echo "Timestamp: $(date -Iseconds)"
echo "API port: $API_PORT | Compose: $ALFA_AI_COMPOSE_FILE"
echo

status=0

check_container() {
  local name=$1
  echo "— $name"
  if ! "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -qx "$name"; then
    echo -e "${RED}✗ container missing${NC}"
    return 1
  fi
  if ! "${DOCKER[@]}" ps --format '{{.Names}}' | grep -qx "$name"; then
    echo -e "${RED}✗ not running${NC}"
    return 1
  fi
  echo -e "${GREEN}✓ running${NC}"
  local h
  h=$("${DOCKER[@]}" inspect "$name" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo none)
  if [[ "$h" != "none" ]]; then
    if [[ "$h" == "healthy" ]]; then
      echo -e "  ${GREEN}health: $h${NC}"
    else
      echo -e "  ${YELLOW}health: $h${NC}"
    fi
  fi
}

http_ok() {
  local url=$1
  curl -fsS --max-time 5 "$url" >/dev/null
}

echo "Containers:"
check_container alfa-ai-postgres || status=1
check_container alfa-ai-redis || status=1
check_container alfa-ai-api || status=1
check_container alfa-ai-litellm || status=1
check_container alfa-ai-nginx || status=1
echo

echo "HTTP:"
if http_ok "http://127.0.0.1:${API_PORT}/health"; then
  echo -e "${GREEN}✓ API GET /health${NC}"
else
  echo -e "${RED}✗ API GET /health failed${NC}"
  status=1
fi

if http_ok "http://127.0.0.1:${API_PORT}/api/health"; then
  echo -e "${GREEN}✓ API GET /api/health${NC}"
  bh="$(curl -fsS --max-time 5 "http://127.0.0.1:${API_PORT}/api/health" 2>/dev/null | grep -o '"build_hash"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  if [[ -n "$bh" && "$bh" != "unknown" && "$bh" != "local" ]]; then
    echo -e "  ${GREEN}build_hash: $bh${NC}"
  elif [[ -n "$bh" ]]; then
    echo -e "  ${YELLOW}WARN: build_hash=$bh (rebuild with scripts/brain_redeploy_api.sh or full_deploy.sh)${NC}"
  fi
else
  echo -e "${RED}✗ API GET /api/health failed${NC}"
  status=1
fi

if [[ "$SKIP_OPTIONAL" != "1" ]]; then
  if http_ok "http://127.0.0.1:${LITELLM_PORT}/health/liveliness"; then
    echo -e "${GREEN}✓ LiteLLM liveliness${NC}"
  else
    echo -e "${YELLOW}⚠ LiteLLM not responding on port ${LITELLM_PORT}${NC}"
  fi
  # nginx.conf only proxies /api/ and /health (no location /) — check /health.
  if http_ok "http://127.0.0.1:${NGINX_PORT}/health"; then
    echo -e "${GREEN}✓ nginx → API /health (port ${NGINX_PORT})${NC}"
  else
    echo -e "${YELLOW}⚠ nginx not responding on port ${NGINX_PORT}${NC}"
  fi
fi

echo
if [[ "$status" -eq 0 ]]; then
  echo -e "${GREEN}Core checks passed.${NC}"
  exit 0
fi
echo -e "${RED}Some checks failed.${NC}"
exit 1
