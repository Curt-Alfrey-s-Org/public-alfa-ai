#!/usr/bin/env bash
# hub SCALE (hub) -- policy routes when data-plane /32 aliases use separate
# physical NICs on orchestrator/24 (legacy split-NIC layout).
#
# SSoT (2026-09-04): br1 is the LAN. While NFS/Petals iface names are enslaved to
# br1, this script is a no-op for member IPs and tables 101/102. IPv4 belongs on
# the bridge. See docs/hub_111_10G_NIC.md.
#
# Official sources:
#   hub bridge: https://www.hub.com/docs/scale/network/interfaces/settingupbridge/
#   ip-link(8): enslaved ifaces show "master <bridge>"; no host IPv4 there.
#   ip-rule(8) / ip-route(8): do not pin storage -> np1 or .157 -> enp7s0 while slaves.
#
# Defaults NAME np1 / enp7s0 for skip logs only. Petals .157 is retired --
# never add table 102. While br1 exists, do not pin storage to a member.
#
# Persist copy (after git pull -- so Post Init is a no-op on br1 members):
#   cp scripts/hub-triple-nic-policy-routes.sh /mnt/hub/alfa-ai/sbin/
#   chmod 700 /mnt/hub/alfa-ai/sbin/hub-triple-nic-policy-routes.sh
# Do not use this script to add policy routes onto br1 slaves.
set -euo pipefail

# ---- CONFIG (edit after cabling) -------------------------------------------
LAN_BRIDGE="${LAN_BRIDGE:-br1}"
MGMT_IFACE="${MGMT_IFACE:-enp11s0f0np0}"       # legacy split-NIC mgmt name
NFS_IFACE="${NFS_IFACE:-enp11s0f1np1}"         # storage/32 -- NFS bind (historical)
PETALS_IFACE="${PETALS_IFACE:-enp7s0}"         # .157/32 -- Petals retired
NFS_SRC="${NFS_SRC:-orchestrator}"
PETALS_SRC="${PETALS_SRC:-orchestrator}"
NFS_TABLE="${NFS_TABLE:-101}"
PETALS_TABLE="${PETALS_TABLE:-102}"
WAIT_SECS="${WAIT_SECS:-120}"
# ----------------------------------------------------------------------------

log() { echo "[hub-triple-nic] $*"; }

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

skip_member_policy() {
  local iface="$1" src="$2" why="$3"
  if [[ "$src" == "$PETALS_SRC" ]]; then
    log "SKIP ${why}: ${src} retired (Petals) -- never route"
    return 0
  fi
  if lan_bridge_exists; then
    log "SKIP ${why}: ${LAN_BRIDGE} exists -- no table via slave"
    return 0
  fi
  if iface_is_bridge_slave "$iface"; then
    local master
    master="$(iface_bridge_master "$iface")"
    log "SKIP ${why}: ${iface} is enslaved to ${master}"
    return 0
  fi
  if addr_on_lan_bridge "$src"; then
    log "SKIP ${why}: ${src} already on ${LAN_BRIDGE}"
    return 0
  fi
  return 1
}

wait_for_addr() {
  local iface="$1" addr="$2"
  local deadline=$((SECONDS + WAIT_SECS))
  while (( SECONDS < deadline )); do
    if ip -4 addr show dev "$iface" 2>/dev/null | grep -qE "${addr}/"; then
      return 0
    fi
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
  log "ARP sysctls: arp_ignore=$(cat /proc/sys/net/ipv4/conf/all/arp_ignore) arp_announce=$(cat /proc/sys/net/ipv4/conf/all/arp_announce)"
}

apply_data_plane() {
  local src="$1" iface="$2" table="$3"
  if skip_member_policy "$iface" "$src" "policy route"; then
    return 1
  fi
  ip rule del from "$src" lookup "$table" 2>/dev/null || true
  ip route flush table "$table" 2>/dev/null || true
  ip route replace orchestrator/24 dev "$iface" scope link table "$table"
  ip rule add from "$src" lookup "$table" priority $((32765 - table))
  log "ok: from $src -> table $table dev $iface"
  return 0
}

setup_policy_route() {
  local src="$1" iface="$2" table="$3" role="$4"
  if skip_member_policy "$iface" "$src" "$role"; then
    return 0
  fi
  if wait_for_addr "$iface" "$src"; then
    apply_data_plane "$src" "$iface" "$table" || true
  else
    log "SKIP ${role}: ${src} not on ${iface}"
  fi
  return 0
}

verify_mgmt_egress() {
  local out
  out="$(ip route get apps 2>/dev/null | head -1 || true)"
  log "unbound egress to apps: $out"
  case "$out" in
    *"dev ${LAN_BRIDGE}"*"src hub"*) log "OK: mgmt egress via ${LAN_BRIDGE}" ;;
    *"dev ${MGMT_IFACE}"*"src hub"*) log "OK: mgmt egress via $MGMT_IFACE" ;;
    *) log "WARN: mgmt egress not via ${LAN_BRIDGE}/hub -- check default route" >&2 ;;
  esac
}

main() {
  need_root
  apply_sysctl

  setup_policy_route "$NFS_SRC" "$NFS_IFACE" "$NFS_TABLE" "NFS"
  log "SKIP Petals: ${PETALS_SRC} retired -- no table ${PETALS_TABLE}"

  verify_mgmt_egress
}

main "$@"
