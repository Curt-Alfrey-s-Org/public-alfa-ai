#!/usr/bin/env bash
# apps public WordPress sites: local stack + Cloudflare tunnel health (read-only).
#
# Run on web-sites (apps): bash deploy/cluster-members/apps/verify-public-sites-lan.sh
# Or from orchestrator: ssh operator@apps 'bash ~/alfa-ai/deploy/cluster-members/apps/verify-public-sites-lan.sh'
#
# HTTP 530 at Cloudflare with OK local nginx usually means cloudflared cannot reach the edge (no WAN).
set -euo pipefail

REPO="${ALFA_AI_REPO:-$HOME/alfa-ai}"
COMMON="$REPO/deploy/cluster-members/_common"

echo "== apps website stacks (local) =="
curl -fsS -o /dev/null -w "example-site-nginx :8092 HTTP %{http_code}\n" --max-time 8 http://127.0.0.1:8092/ || echo "FAIL example-site :8092"

if docker exec alfa-nginx wget -qO- --timeout=5 http://127.0.0.1/ >/dev/null 2>&1; then
  echo "OK  alfa-nginx -> wordpress (internal)"
else
  echo "WARN alfa-nginx internal probe slow/fail (check alfa_wordpress_1 logs)"
fi

echo ""
echo "== Cloudflare tunnels (need WAN to 198.41.x.x) =="
for c in cf-alfa cf-example-site; do
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then
    err="$(docker logs "$c" 2>&1 | grep -c 'Failed to dial a quic connection' || true)"
    echo "$c: running, recent quic dial errors in log: $err"
  else
    echo "$c: not running"
  fi
done

echo ""
if [[ -x "$COMMON/verify-lan-gateway-reachability.sh" ]] || [[ -f "$COMMON/verify-lan-gateway-reachability.sh" ]]; then
  bash "$COMMON/verify-lan-gateway-reachability.sh" || true
fi

echo ""
echo "LAN example-site (from any host on orchestrator/24): http://apps/"
echo "Public URLs need cf-* tunnels registered after gateway fix."
