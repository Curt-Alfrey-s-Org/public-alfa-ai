#!/usr/bin/env bash
set -euo pipefail
#
# DEPRECATED for cluster LAN split (2026-07). Use scripts/hub-triple-nic-setup.sh
# instead (storage on np1, .157 on enp6s0, same orchestrator/24). Remove this script
# from POSTINIT if still registered — do not run both at boot.
#
# hub SCALE — policy route for a second LAN / Wi‑Fi‑extender leg so traffic
# sourced from a dedicated IPv4 uses its own default gateway (parallel downloads).
#
# Run ON the hub host (SSH). Intended to be called from UI:
#   System → Advanced → Init/Shutdown Scripts → POSTINIT → Script (path below).
#
# --- Where to put this file ---
#
# The Init/Shutdown "Script" file picker only lists pool paths under **/mnt** (it
# does not show the boot pool or /root). Pick one of:
#
#   A) Copy next to your git checkout (easy to refresh after git pull), e.g.:
#        mkdir -p /mnt/hub/alfa-ai/sbin
#        cp .../alfa-ai/scripts/hub_policy_route_second_wan.sh /mnt/hub/alfa-ai/sbin/
#        chmod 700 /mnt/hub/alfa-ai/sbin/hub_policy_route_second_wan.sh
#      Then in the UI choose that path under /mnt → HDDs → Alfa-AI → sbin.
#
#   B) Keep a copy under /root/scripts for SSH use only; in the UI use **Type:
#      Command** with a one-liner (if your SCALE build allows it), e.g.:
#        /bin/bash /root/scripts/hub_policy_route_second_wan.sh
#
# POSTINIT runs after pools are imported; a path under /mnt/HDDs/... is fine.
# Do NOT rely only on /tmp. Avoid paths on datasets that mount very late in boot
# unless you increase WAIT_SECS.
#
# --- When you move the extender / change Wi‑Fi ---
#
# Edit the CONFIG block only: interface name, your IPv4 on that leg, that leg's
# gateway, and (optional) routing table id + rule priority. Then re-copy to
# /root/scripts/ and reboot (or run this script once by hand with sudo).
#
# If the second leg uses DHCP and the address changes, either set a static alias
# in hub for that NIC or update SECOND_WAN_SRC here after DHCP changes.
# After edits, sync the copy you selected in the UI (e.g. under /mnt/.../sbin/).

# ---- CONFIG (edit for your site) -------------------------------------------
SECOND_WAN_IFACE="${SECOND_WAN_IFACE:-enp11s0f1np1}"
SECOND_WAN_SRC="${SECOND_WAN_SRC:-orchestrator}"   # IPv4 alias on SECOND_WAN_IFACE
SECOND_WAN_GW="${SECOND_WAN_GW:-orchestrator}"       # Default gateway on that subnet
POLICY_TABLE="${POLICY_TABLE:-100}"                 # linux "ip route table" number
POLICY_RULE_PRIORITY="${POLICY_RULE_PRIORITY:-5000}" # lower = higher precedence vs other rules
WAIT_SECS="${WAIT_SECS:-120}"                       # max wait for alias to appear
# ----------------------------------------------------------------------------

log() { echo "[hub-policy-route-second-wan] $*"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log "run as root (sudo $0)" >&2
    exit 1
  fi
}

wait_for_alias() {
  local deadline=$((SECONDS + WAIT_SECS))
  while (( SECONDS < deadline )); do
    if ip -4 addr show dev "$SECOND_WAN_IFACE" 2>/dev/null | grep -qE "${SECOND_WAN_SRC}/"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

apply_routes() {
  ip rule del from "$SECOND_WAN_SRC" lookup "$POLICY_TABLE" 2>/dev/null || true
  ip route flush table "$POLICY_TABLE" 2>/dev/null || true
  ip route replace default via "$SECOND_WAN_GW" dev "$SECOND_WAN_IFACE" table "$POLICY_TABLE"
  ip rule add from "$SECOND_WAN_SRC" lookup "$POLICY_TABLE" priority "$POLICY_RULE_PRIORITY"
}

main() {
  need_root
  log "waiting for ${SECOND_WAN_SRC} on ${SECOND_WAN_IFACE} (up to ${WAIT_SECS}s) ..."
  if ! wait_for_alias; then
    log "timeout: ${SECOND_WAN_SRC} not on ${SECOND_WAN_IFACE}; skipping (no policy routes added)"
    exit 0
  fi
  apply_routes
  log "ok: table ${POLICY_TABLE} default via ${SECOND_WAN_GW} dev ${SECOND_WAN_IFACE}; rule from ${SECOND_WAN_SRC}"
}

main "$@"
