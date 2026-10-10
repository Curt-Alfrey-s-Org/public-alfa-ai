#!/usr/bin/env bash
# Start Cloudflare tunnel for probilliardssoftware.com on apps.
# Nginx origin (probilliards-nginx) is managed by stacksapps.yml probilliards-nginx stack.
#
# Usage: bash deploy/cluster-members/_common/start-rankings-public-ingress-105.sh
set -euo pipefail

RANKINGS_ROOT="${RANKINGS_ROOT:-/home/operator/rankings-bot}"
TUNNEL_SCRIPT="$RANKINGS_ROOT/scripts/start_cf_probilliards.sh"

if [[ ! -f "$TUNNEL_SCRIPT" ]]; then
  echo "ERROR: missing $TUNNEL_SCRIPT" >&2
  exit 1
fi

if ! docker network inspect tunnel_network >/dev/null 2>&1; then
  echo "Creating prerequisite Docker network: tunnel_network"
  docker network create tunnel_network >/dev/null
fi

echo "== start cf-probilliards (probilliardssoftware.com tunnel) =="
bash "$TUNNEL_SCRIPT"

echo "Waiting for tunnel registration (up to 120s)..."
for i in $(seq 1 24); do
  if docker logs cf-probilliards --since 2m 2>&1 | grep -q 'Registered tunnel connection'; then
    echo "  OK: tunnel registered"
    exit 0
  fi
  sleep 5
done

echo "WARN: tunnel container up but no Registered tunnel connection in 120s" >&2
echo "      Check: docker logs cf-probilliards --tail 30" >&2
exit 1
