#!/usr/bin/env bash
# Idempotent UFW allow for operator console / LiteLLM (LAN +  tailnet).
#
# Usage:
#   sudo bash deploy/cluster-members/_common/ensure-operator-console-ufw.sh brain
#   sudo bash deploy/cluster-members/_common/ensure-operator-console-ufw.sh edge
#
# brain: ports 8413 + 8420 on hub -- LAN only ( admin uses inference edge :8420)
# edge:  port 8420 on inference -- LAN + tailnet (canonical  admin login)
#
# Tailnet CIDR: https://.com/kb/1015/100-64-100-100 (100.64.0.0/10)
set -euo pipefail

ROLE="${1:-brain}"
LAN_CIDR="${ALFA_LAN_CIDR:-orchestrator/24}"
TAILNET_CIDR="${ALFA_TAILNET_CIDR:-100.64.0.0/10}"

if ! command -v ufw >/dev/null 2>&1; then
  echo "WARN: ufw not found; skip firewall (configure hub Network Firewall manually)" >&2
  exit 0
fi

if ! sudo ufw status 2>/dev/null | grep -qiE 'Status: active'; then
  echo "WARN: ufw inactive; skip (ports may still be blocked by hub firewall)" >&2
  exit 0
fi

ensure_allow() {
  local port="$1"
  local tag="$2"
  local allow_tailnet="${3:-1}"
  local lan_comment="${tag} LAN"
  if sudo ufw status numbered 2>/dev/null | grep -qE "${port}/tcp.*${tag}"; then
    echo "  ufw OK: port ${port} (${tag})"
    return 0
  fi
  sudo ufw allow from "$LAN_CIDR" to any port "$port" proto tcp comment "$lan_comment" || true
  if [[ "$allow_tailnet" == "1" ]]; then
    sudo ufw allow from "$TAILNET_CIDR" to any port "$port" proto tcp comment "${tag} tailnet" || true
    echo "  ufw allow: port ${port} (${tag}) from ${LAN_CIDR} and ${TAILNET_CIDR}"
  else
    echo "  ufw allow: port ${port} (${tag}) from ${LAN_CIDR} only (no tailnet on brain)"
  fi
}

echo "== ensure-operator-console-ufw ($ROLE) =="

case "$ROLE" in
  brain)
    ensure_allow 8413 'LiteLLM' 0
    ensure_allow 8420 'ALFa operator' 0
    ;;
  edge)
    ensure_allow 8420 'ALFa edge' 1
    ;;
  *)
    echo "Usage: $0 brain|edge" >&2
    exit 1
    ;;
esac

sudo ufw reload 2>/dev/null || true
echo "ensure-operator-console-ufw OK"
