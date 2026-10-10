#!/usr/bin/env bash
# VM 105 (apps): mgmt apps on bond0 (enp6s18) + data plane orchestrator on enp6s19.
# Pattern matches ai-148 (inference mgmt / .147 USB data plane).
#
# Prerequisites:
#   - Proxmox hypervisor exposes a second virtio NIC to VM 105 (enp6s19), bridged to USB-Ethernet.
#   - Run on hypervisor first: sudo bash deploy/cluster-members/hypervisor/setup-dual-ip-data-plane.sh
#
# Usage (on apps as ansible):
#   sudo bash deploy/cluster-members/apps/setup-dual-ip-data-plane.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
SRC="$SCRIPT_DIR/netplan-dual-ip-data-plane.yaml"
DEST="/etc/netplan/01-bond.yaml"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root (sudo bash $0)" >&2
  exit 1
fi

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: missing $SRC" >&2
  exit 1
fi

echo "== VM 105 dual IP: apps mgmt (bond0) + .104 data plane (enp6s19) =="
cp -a "$DEST" "${DEST}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
install -m 600 "$SRC" "$DEST"
echo "Wrote $DEST"

# Same-subnet ARP flux fix (must precede netplan apply so the second NIC behaves).
ARP_SRC="$SCRIPT_DIR/../_common/60-alfa-dual-nic.conf"
ARP_DEST="/etc/sysctl.d/60-alfa-dual-nic.conf"
if [[ -f "$ARP_SRC" ]]; then
  install -m 644 "$ARP_SRC" "$ARP_DEST"
  sysctl --system >/dev/null
  echo "Applied ARP sysctls: arp_ignore=$(cat /proc/sys/net/ipv4/conf/all/arp_ignore) arp_announce=$(cat /proc/sys/net/ipv4/conf/all/arp_announce)"
else
  echo "WARN: missing $ARP_SRC -- ARP flux fix not applied" >&2
fi

netplan generate
echo "Applying (SSH may drop briefly)..."
netplan apply
sleep 3

echo ""
ip -br addr | grep -E 'bond0|enp6s18|enp6s19' || true
echo ""
ip route | head -6 || true

if ip link show enp6s19 >/dev/null 2>&1; then
  if ip -br addr show enp6s19 | grep -q 'orchestrator'; then
    echo "OK: enp6s19 has orchestrator"
  else
    echo "WARN: enp6s19 present but .104 not assigned" >&2
  fi
else
  echo "WARN: enp6s19 not present yet -- add net1 on Proxmox VM 105 (see pve-229 script)" >&2
fi

echo ""
echo "== source-routing verify =="
ip rule | grep -E 'lookup 101|from orchestrator' || echo "WARN: routing-policy rule for .104 missing" >&2
ip route show table 101 2>/dev/null || true
egress="$(ip route get hub 2>/dev/null | head -1 || true)"
echo "egress to hub: $egress"
case "$egress" in
  *"dev bond0"*"src apps"*) echo "OK: unbound LAN egress uses mgmt bond0 (apps)" ;;
  *) echo "WARN: unbound egress not via bond0/apps -- check /32 + main route" >&2 ;;
esac

echo "Done. Mgmt SSH: operator@apps | Data plane: orchestrator"
