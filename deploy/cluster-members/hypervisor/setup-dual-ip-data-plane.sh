#!/usr/bin/env bash
# Proxmox host pve-i5.home (hypervisor): onboard mgmt hypervisor + USB data plane .228.
# Adds vmbr1 on USB-Ethernet and optional second virtio (net1) on VM 105 for .104.
#
# Run on Proxmox hypervisor as root (console or SSH):
#   cd /path/to/alfa-ai && sudo bash deploy/cluster-members/hypervisor/setup-dual-ip-data-plane.sh
#
# Ref: https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#sysadmin_network_configuration
set -euo pipefail

VMID="${ALFA_VM105_ID:-105}"
MGMT_IP="orchestrator"
DATA_IP="orchestrator"
GW="${ALFA_LAN_GW:-orchestrator}"
IFACES="/etc/network/interfaces"
FRAG="/etc/network/interfaces.d/alfa-dual-ip"

mkdir -p /etc/network/interfaces.d

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root on Proxmox hypervisor" >&2
  exit 1
fi

echo "== pve-i5.home dual IP: ${MGMT_IP} mgmt + ${DATA_IP} USB data plane =="

# Detect onboard (already carries hypervisor / vmbr0) and USB Ethernet.
mapfile -t candidates < <(ip -o link show | awk -F': ' '!/lo|bond|veth|docker|fwbr|tap|vmbr||w/ {print $2}')
usb_if=""
mgmt_port=""

vmbr0_port="$(awk '/^[\t ]*bridge-ports/ {print $2; exit}' "$IFACES" 2>/dev/null || true)"

for ifc in "${candidates[@]}"; do
  [[ "$ifc" == "$vmbr0_port" ]] && mgmt_port="$ifc"
  parent=$(readlink -f "/sys/class/net/${ifc}/device" 2>/dev/null || true)
  if [[ "$parent" == *usb* ]]; then
    usb_if="$ifc"
  fi
done

# Fallback: enx* rename is usually USB Ethernet.
if [[ -z "$usb_if" ]]; then
  for ifc in "${candidates[@]}"; do
    if [[ "$ifc" == enx* && "$ifc" != "$vmbr0_port" ]]; then
      usb_if="$ifc"
      break
    fi
  done
fi

if [[ -z "$usb_if" ]]; then
  echo "ERROR: USB Ethernet not found. Plug adapter and re-run." >&2
  echo "  Candidates: ${candidates[*]}" >&2
  exit 1
fi

echo "  USB NIC: $usb_if"
echo "  Mgmt bridge port (existing vmbr0 slave): ${mgmt_port:-unknown}"

if grep -q "alfa-dual-ip" "$IFACES" 2>/dev/null || [[ -f "$FRAG" ]]; then
  echo "  Fragment already present; updating $FRAG"
fi

cat >"$FRAG" <<EOF
# alfa-dual-ip: USB data plane ${DATA_IP} (no default route on USB)
auto ${usb_if}
iface ${usb_if} inet manual

auto vmbr1
iface vmbr1 inet static
    address ${DATA_IP}/24
    bridge-ports ${usb_if}
    bridge-stp off
    bridge-fd 0
    # Data plane only -- no gateway here.
EOF

if ! grep -q 'source /etc/network/interfaces.d/\*' "$IFACES" 2>/dev/null; then
  echo "source /etc/network/interfaces.d/*" >>"$IFACES"
fi

if ! grep -q 'alfa-dual-ip' "$IFACES" 2>/dev/null; then
  echo "# alfa-dual-ip fragment in interfaces.d/alfa-dual-ip" >>"$IFACES"
fi

echo "Wrote $FRAG"
echo "Applying host network (may interrupt briefly)..."
ifreload -a

sleep 2
ip -br addr | grep -E 'vmbr0|vmbr1|'"$usb_if"

# VM 105: second virtio on vmbr1 for guest .104
if command -v qm >/dev/null 2>&1; then
  if qm status "$VMID" >/dev/null 2>&1; then
    if qm config "$VMID" | grep -q '^net1:'; then
      echo "  VM ${VMID} net1 already configured:"
      qm config "$VMID" | grep '^net[0-9]:'
    else
      echo "  Adding VM ${VMID} net1 virtio on vmbr1..."
      qm set "$VMID" -net1 "virtio,bridge=vmbr1,firewall=1"
      echo "  net1 added. Reboot VM 105 or run setup-dual-ip-data-plane.sh inside guest."
    fi
  else
    echo "WARN: VM ${VMID} not found; skip net1" >&2
  fi
fi

echo ""
echo "Done. Host mgmt: ${MGMT_IP} | Host data plane: ${DATA_IP}"
echo "Next on VM 105: sudo bash deploy/cluster-members/apps/setup-dual-ip-data-plane.sh"
