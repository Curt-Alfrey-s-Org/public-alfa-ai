#!/usr/bin/env bash
# ai-148: bond eno1 + USB NIC (active-backup). Single LAN IP orchestrator on bond0.
#
# Run on inference (console or SSH; SSH may drop for ~30s during apply):
#   sudo bash deploy/cluster-members/inference-coordinator/setup-bond-active-backup.sh
#
# Or from repo root after git clone:
#   sudo bash setup-bond-active-backup.sh
set -euo pipefail

NETPLAN_DIR="/etc/netplan"
BACKUP="${NETPLAN_DIR}/00-installer-config.yaml.bak-$(date +%Y%m%d-%H%M%S)"
TARGET="${NETPLAN_DIR}/01-ai148-bond.yaml"
OLD="${NETPLAN_DIR}/00-installer-config.yaml"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root (sudo bash $0)" >&2
  exit 1
fi

echo "== ai-148 bond setup (active-backup, IP orchestrator) =="

if [[ -f "$OLD" ]]; then
  cp -a "$OLD" "$BACKUP"
  echo "Backed up $OLD -> $BACKUP"
fi

# Disable DHCP on slaves; one static IP on bond0. Gateway from live route.
GW="$(ip route show default | awk '{print $3; exit}')"
GW="${GW:-orchestrator}"
echo "Using gateway: $GW"

cat >"$TARGET" <<EOF
# ai-148 Petals worker -- bond eno1 (primary) + USB NIC (backup)
network:
  version: 2
  renderer: networkd
  ethernets:
    eno1:
      dhcp4: no
      dhcp6: no
      match:
        macaddress: b4:2e:99:38:2f:c9
      set-name: eno1
    nic_usb:
      dhcp4: no
      dhcp6: no
      match:
        macaddress: 7c:c2:c6:46:ec:53
      set-name: nic_usb
  bonds:
    bond0:
      interfaces:
        - eno1
        - nic_usb
      parameters:
        mode: active-backup
        primary: eno1
        mii-monitor-interval: 100
      dhcp4: no
      addresses:
        - orchestrator/24
      routes:
        - to: default
          via: ${GW}
      nameservers:
        addresses:
          - ${GW}
EOF

chmod 600 "$TARGET"
echo "Wrote $TARGET"

# Disable installer DHCP config so it does not fight the bond (netplan merges all YAML).
if [[ -f "$OLD" ]]; then
  mv "$OLD" "${OLD}.disabled"
  echo "Disabled $OLD -> ${OLD}.disabled"
fi

modprobe bonding 2>/dev/null || true

echo "Validating netplan..."
netplan generate

echo ""
echo "Applying (SSH may drop ~10s while bond0 comes up)..."
netplan apply
sleep 3

echo ""
echo "== bond0 status =="
ip -br addr show bond0 || true
if [[ -f /proc/net/bonding/bond0 ]]; then
  sed -n '1,25p' /proc/net/bonding/bond0
else
  echo "WARN: bond0 not present -- check: journalctl -u systemd-networkd -n 30" >&2
  exit 1
fi

echo ""
echo "Done. SSH target: operator@orchestrator (bond0)"
echo "PETALS_ANNOUNCE_IP=orchestrator"
