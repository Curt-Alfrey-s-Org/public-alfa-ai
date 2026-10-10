#!/usr/bin/env bash
# ai-148: bond eno1 + USB NIC (IEEE 802.3ad / LACP). Single LAN IP orchestrator on bond0.
#
# Prerequisite: switch/router LAG (802.3ad) on the two ports cabled to eno1 + USB.
# AXE300 allows one 2-port LAG -- move it from hypervisor to inference before apply.
#
# Run on inference (console or SSH; SSH may drop ~30s during apply):
#   sudo bash deploy/cluster-members/inference-coordinator/setup-bond-lacp.sh
#
# Revert: setup-bond-active-backup.sh or setup-dual-ip-data-plane.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/netplan-bond-lacp.yaml"
NETPLAN_DIR="/etc/netplan"
TARGET="${NETPLAN_DIR}/01-ai148-bond.yaml"
BACKUP="${TARGET}.bak-$(date +%Y%m%d-%H%M%S)"
SYSCTL_DUAL="${SYSCTL_DUAL:-/etc/sysctl.d/60-alfa-dual-nic.conf}"

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

echo "== ai-148 bond setup (802.3ad LACP, IP orchestrator) =="
if [[ -z "$usb_if" ]]; then
  echo "ERROR: USB Ethernet not found -- plug adapter and re-run" >&2
  exit 1
fi
echo "  USB NIC: $usb_if"

if [[ -f "$TARGET" ]]; then
  cp -a "$TARGET" "$BACKUP"
  echo "Backed up $TARGET -> $BACKUP"
fi

GW="$(ip route show default | awk '{print $3; exit}')"
GW="${GW:-orchestrator}"
echo "Using gateway: $GW"

install -m 600 "$SRC" "$TARGET"
sed -i "s/via: orchestrator/via: ${GW}/" "$TARGET"
sed -i "s/- orchestrator/- ${GW}/" "$TARGET"

# If USB uses a different kernel name than nic_usb, keep MAC match (stable).
if [[ "$usb_if" != "nic_usb" && "$usb_if" != "enx7cc2c646ec53" ]]; then
  echo "  Note: USB presents as $usb_if; netplan matches MAC 7c:c2:c6:46:ec:53 -> nic_usb"
fi

if [[ -f "$SYSCTL_DUAL" ]]; then
  mv "$SYSCTL_DUAL" "${SYSCTL_DUAL}.disabled-$(date +%Y%m%d-%H%M%S)"
  echo "Disabled dual-NIC ARP sysctl (not needed for single-IP LACP bond)"
  sysctl --system >/dev/null 2>&1 || true
fi

modprobe bonding 2>/dev/null || true

echo "Validating netplan..."
netplan generate

echo ""
echo "Applying (SSH may drop ~10s while bond0 comes up)..."
netplan apply
sleep 5

echo ""
echo "== bond0 status =="
ip -br addr show bond0 || true
if [[ ! -f /proc/net/bonding/bond0 ]]; then
  echo "ERROR: bond0 not present -- check: journalctl -u systemd-networkd -n 30" >&2
  exit 1
fi
sed -n '1,40p' /proc/net/bonding/bond0

bond_mode="$(awk -F': ' '/Bonding Mode/ {print $2; exit}' /proc/net/bonding/bond0)"
ports="$(awk -F': ' '/Number of ports/ {print $2; exit}' /proc/net/bonding/bond0)"
ports="${ports// /}"

if [[ "$bond_mode" != *"802.3ad"* ]]; then
  echo "ERROR: bond mode is not 802.3ad (got: $bond_mode)" >&2
  exit 1
fi

if [[ "$ports" != "2" ]]; then
  echo "WARN: LACP aggregate shows Number of ports: ${ports:-unknown} (want 2)" >&2
  echo "  Check AXE300 LAG ports match both cables; partner MAC should not be 00:00:00:00:00:00" >&2
  echo "  Re-check: cat /proc/net/bonding/bond0" >&2
  exit 2
fi

echo ""
echo "OK: LACP bond0 up with 2 ports. SSH: operator@orchestrator"
echo "Retired: orchestrator data-plane IP (use inference only)"
