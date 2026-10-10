#!/usr/bin/env bash
# ai-148: mgmt orchestrator on bond0 (eno1) + data plane orchestrator on USB NIC.
#
# Usage (on inference):
#   sudo bash deploy/cluster-members/inference-coordinator/setup-dual-ip-data-plane.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/netplan-dual-ip-data-plane.yaml"
DEST="/etc/netplan/01-ai148-bond.yaml"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root (sudo bash $0)" >&2
  exit 1
fi

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: missing $SRC" >&2
  exit 1
fi

usb_if=""
for ifc in $(ip -o link show | awk -F': ' '!/lo|bond|veth|docker|br-/ {print $2}'); do
  parent=$(readlink -f "/sys/class/net/${ifc}/device" 2>/dev/null || true)
  if [[ "$ifc" == enx* && "$parent" == *usb* ]]; then
    usb_if="$ifc"
    break
  fi
done
if [[ -z "$usb_if" ]]; then
  for ifc in $(ip -o link show | awk -F': ' '/enx/ {print $2}'); do
    [[ "$ifc" != "eno1" ]] && usb_if="$ifc" && break
  done
fi

echo "== ai-148 dual IP: inference mgmt (bond0) + .147 data plane (USB) =="
if [[ -n "$usb_if" && "$usb_if" != "enx96ae5e1c7cd2" ]]; then
  echo "  USB NIC detected as $usb_if (patching netplan match.name)"
  sed "s/name: enx96ae5e1c7cd2/name: ${usb_if}/" "$SRC" > /tmp/ai148-netplan.yaml
  install -m 600 /tmp/ai148-netplan.yaml "$DEST"
else
  cp -a "$DEST" "${DEST}.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  install -m 600 "$SRC" "$DEST"
fi

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

ip -br addr | grep -E 'bond0|eno1|enx|nic_usb' || true
echo ""
ip route | head -6 || true
echo ""
echo "== source-routing verify =="
ip rule | grep -E 'lookup 101|from orchestrator' || echo "WARN: routing-policy rule for .147 missing" >&2
ip route show table 101 2>/dev/null || true
egress="$(ip route get hub 2>/dev/null | head -1 || true)"
echo "egress to hub: $egress"
case "$egress" in
  *"dev bond0"*"src orchestrator"*) echo "OK: unbound LAN egress uses mgmt bond0 (inference)" ;;
  *) echo "WARN: unbound egress not via bond0/inference -- check /32 + main route" >&2 ;;
esac
echo "Done. Mgmt: orchestrator | Data plane: orchestrator"
