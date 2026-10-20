#!/usr/bin/env bash
# hub SCALE (hub) -- optional /32 + policy routes on separate physical NICs.
#
# SSoT (2026-09-04): br1 is the LAN. IPv4 belongs on the bridge, not on enslaved
# members. See docs/hub_111_10G_NIC.md and .cursor/rules/hub-network-aliases.mdc.
#
# Official sources:
#   hub bridge: https://www.hub.com/docs/scale/network/interfaces/settingupbridge/
#   ip-link(8): enslaved ifaces show "master <bridge>"; no host IPv4 there.
#   ip-address(8): assign addresses on the bridge device.
#   ip-rule(8) / ip-route(8): policy tables pinning a VIP to a slave while it is in
#     br1 are wrong (same L2).
#
# Configure hub/24 + storage/32 on br1 in hub UI. This script must NOT assign
# IPv4 on bridge members and must NEVER assign retired Petals .157.
#
# hub mapping (iface names for CONFIG / skip logs only):
#   enp11s0f0np0  9c:6b:00:65:dc:2b  historical mgmt name
#   enp11s0f1np1  9c:6b:00:65:df:4a  historical NFS name
#   enp7s0        9c:6b:00:65:d7:9b  historical Petals (retired)
#   enp6s0        9c:6b:00:65:d4:7d  spare 1G
#
# Persist copy (after git pull -- so Post Init stops re-adding member /32s):
#   mkdir -p /mnt/hub/alfa-ai/sbin
#   cp /mnt/hub/alfa-ai/repo/alfa-ai/scripts/hub-triple-nic-setup.sh /mnt/hub/alfa-ai/sbin/
#   chmod 700 /mnt/hub/alfa-ai/sbin/hub-triple-nic-setup.sh
# Do not use this script to add IPv4 on br1 members.
set -euo pipefail

LAN_BRIDGE="${LAN_BRIDGE:-br1}"
MGMT_IFACE="${MGMT_IFACE:-enp11s0f0np0}"
NFS_IFACE="${NFS_IFACE:-enp11s0f1np1}"
PETALS_IFACE="${PETALS_IFACE:-enp7s0}"   # .157 retired; historical name only
NFS_SRC="${NFS_SRC:-orchestrator}"
PETALS_SRC="${PETALS_SRC:-orchestrator}"
NFS_TABLE="${NFS_TABLE:-101}"
PETALS_TABLE="${PETALS_TABLE:-102}"
WAIT_LINK_SECS="${WAIT_LINK_SECS:-60}"

log() { echo "[hub-triple-nic-setup] $*"; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || { log "run as root" >&2; exit 1; }
}

# ip-link(8): enslaved members show "master <bridge>" in link output.
iface_is_bridge_slave() {
  local iface="$1"
  ip -o link show "$iface" 2>/dev/null | grep -q ' master '
}

iface_bridge_master() {
  local iface="$1"
  ip -o link show "$iface" 2>/dev/null | sed -n 's/.* master \([^ ]*\).*/\1/p' | head -1
}

addr_on_iface() {
  local iface="$1" addr="$2"
  ip -4 addr show dev "$iface" 2>/dev/null | grep -qE "${addr}/"
}

addr_on_lan_bridge() {
  addr_on_iface "$LAN_BRIDGE" "$1"
}

lan_bridge_exists() {
  ip link show "$LAN_BRIDGE" >/dev/null 2>&1
}

skip_member_ipv4() {
  local iface="$1" addr="$2" why="$3"
  if [[ "$addr" == "$PETALS_SRC" ]]; then
    log "SKIP ${why}: ${addr} retired (Petals) -- never assign"
    return 0
  fi
  if lan_bridge_exists; then
    log "SKIP ${why}: ${LAN_BRIDGE} exists -- IPv4 on bridge only (hub UI)"
    return 0
  fi
  if iface_is_bridge_slave "$iface"; then
    local master
    master="$(iface_bridge_master "$iface")"
    log "SKIP ${why}: ${iface} is enslaved to ${master}"
    return 0
  fi
  if addr_on_lan_bridge "$addr"; then
    log "SKIP ${why}: ${addr} already on ${LAN_BRIDGE}"
    return 0
  fi
  return 1
}

wait_for_link() {
  local iface="$1"
  local deadline=$((SECONDS + WAIT_LINK_SECS))
  while (( SECONDS < deadline )); do
    if ip link show "$iface" 2>/dev/null | grep -q 'state UP'; then
      return 0
    fi
    ip link set "$iface" up 2>/dev/null || true
    sleep 2
  done
  return 1
}

apply_sysctl() {
  local dest="/etc/sysctl.d/60-alfa-dual-nic.conf"
  cat >"$dest" <<'EOF'
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
EOF
  sysctl --system >/dev/null 2>&1 || sysctl -p "$dest" >/dev/null
  log "ARP sysctls applied"
}

assign_data_ip() {
  local iface="$1" addr="$2"
  if skip_member_ipv4 "$iface" "$addr" "assign"; then
    return 1
  fi
  ip link set "$iface" up 2>/dev/null || true
  # Remove any /24 the kernel or a failed DHCP pass may have added.
  ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2}' | while read -r cidr; do
    ip addr del "$cidr" dev "$iface" 2>/dev/null || true
  done
  ip addr replace "${addr}/32" dev "$iface"
  log "assigned ${addr}/32 on ${iface}"
  return 0
}

apply_data_plane() {
  local src="$1" iface="$2" table="$3"
  if skip_member_ipv4 "$iface" "$src" "policy route"; then
    return 1
  fi
  ip rule del from "$src" lookup "$table" 2>/dev/null || true
  ip route flush table "$table" 2>/dev/null || true
  ip route replace orchestrator/24 dev "$iface" scope link table "$table"
  ip rule add from "$src" lookup "$table" priority $((32765 - table))
  log "policy route: from ${src} -> table ${table} dev ${iface}"
  return 0
}

verify_mgmt_egress() {
  local out
  out="$(ip route get apps 2>/dev/null | head -1 || true)"
  log "unbound egress to apps: ${out}"
  case "$out" in
    *"dev ${LAN_BRIDGE}"*"src hub"*) log "OK: mgmt uses ${LAN_BRIDGE}" ;;
    *"dev ${MGMT_IFACE}"*"src hub"*) log "OK: mgmt uses ${MGMT_IFACE}" ;;
    *) log "WARN: mgmt egress not via ${LAN_BRIDGE}/hub" >&2 ;;
  esac
}

setup_nic() {
  local iface="$1" addr="$2" table="$3" role="$4"
  if skip_member_ipv4 "$iface" "$addr" "$role"; then
    return 0
  fi
  if ! wait_for_link "$iface"; then
    log "SKIP ${role}: ${iface} has no link (cable missing?)"
    return 0
  fi
  if assign_data_ip "$iface" "$addr"; then
    apply_data_plane "$addr" "$iface" "$table" || true
  fi
  return 0
}

main() {
  need_root
  apply_sysctl
  setup_nic "$NFS_IFACE" "$NFS_SRC" "$NFS_TABLE" "NFS" || true
  log "SKIP Petals: ${PETALS_SRC} retired -- not assigned"
  verify_mgmt_egress
  log "done -- verify: ip -br addr show ${LAN_BRIDGE}; ip route get orchestrator"
}

main "$@"
