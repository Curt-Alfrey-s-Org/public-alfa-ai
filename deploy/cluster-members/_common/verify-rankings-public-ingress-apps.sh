#!/usr/bin/env bash
# Verify probilliardssoftware.com public ingress on apps after deploy.
# Chain: cf-probilliards -> probilliards-nginx:80 -> rankings-bot-api:8003
#
# Usage: bash deploy/cluster-members/_common/verify-rankings-public-ingress-105.sh
# Exit 0 when local origin + containers OK; warns on public URL if tunnel still registering.
set -uo pipefail

RANKINGS_ROOT="${RANKINGS_ROOT:-/home/operator/rankings-bot}"
PUBLIC_URL="${PUBLIC_URL:-https://www.probilliardssoftware.com/rankings}"
LOCAL_ORIGIN_URL="${LOCAL_ORIGIN_URL:-http://127.0.0.1:8088/rankings}"
TUNNEL_CONTAINER="${TUNNEL_CONTAINER:-cf-probilliards}"
NGINX_CONTAINER="${NGINX_CONTAINER:-probilliards-nginx}"
FAIL=0

die_check() {
  local label="$1"
  shift
  if "$@"; then
    echo "  OK: $label"
  else
    echo "  FAIL: $label" >&2
    FAIL=1
  fi
}

echo "== verify rankings public ingress (apps) =="

die_check "$NGINX_CONTAINER container running" \
  bash -c "docker ps --format '{{.Names}}' | grep -qx '$NGINX_CONTAINER'"

die_check "$TUNNEL_CONTAINER container running" \
  bash -c "docker ps --format '{{.Names}}' | grep -qx '$TUNNEL_CONTAINER'"

die_check "local origin $LOCAL_ORIGIN_URL returns HTTP 200" \
  bash -c "code=\$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 15 '$LOCAL_ORIGIN_URL' 2>/dev/null || echo 000); [[ \"\$code\" == \"200\" ]]"

if docker logs "$TUNNEL_CONTAINER" --since 10m 2>&1 | grep -q 'Registered tunnel connection'; then
  echo "  OK: $TUNNEL_CONTAINER registered with Cloudflare edge (last 10m)"
else
  echo "  WARN: $TUNNEL_CONTAINER has no Registered tunnel connection in last 10m" >&2
  echo "        Run: cd $RANKINGS_ROOT && ./scripts/start_cf_probilliards.sh" >&2
  FAIL=1
fi

pub_code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 20 "$PUBLIC_URL" 2>/dev/null || echo 000)"
if [[ "$pub_code" == "200" ]]; then
  echo "  OK: public URL $PUBLIC_URL returns HTTP 200"
else
  echo "  WARN: public URL $PUBLIC_URL returned HTTP $pub_code (tunnel may still be registering)" >&2
  if [[ "$FAIL" -eq 0 ]]; then
    echo "        Local origin is up; retry public URL in 1-2 minutes." >&2
  fi
fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "RESULT: FAIL (rankings public ingress incomplete)" >&2
  exit 1
fi
echo "RESULT: OK (local ingress; check public URL above)"
