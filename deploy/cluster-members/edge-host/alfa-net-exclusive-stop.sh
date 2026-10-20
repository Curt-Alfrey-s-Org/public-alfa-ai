#!/bin/bash
# ExecStopPost helper: do not enable Wi-Fi while eth0 still has carrier
# (that would put orchestrator on two interfaces). If wired carrier is
# absent, enable the radio and activate the Wi-Fi profile so a stopped unit
# still leaves the board reachable. Official: nmcli(1) connection up,
# https://www.networkmanager.dev/docs/api/latest/nmcli.html
# systemd.service(5) ExecStopPost.
set -uo pipefail
export LC_ALL=C

[ -r /etc/default/alfa-net-exclusive ] && . /etc/default/alfa-net-exclusive

ETH_DEV=${ETH_DEV:-eth0}
WIFI_CON=${WIFI_CON:-StarWarz2}
UP_WAIT_SEC=${UP_WAIT_SEC:-30}

carrier=$(cat "/sys/class/net/${ETH_DEV}/carrier" 2>/dev/null || echo 0)
if [ "$carrier" = "1" ]; then
    nmcli radio wifi off || true
    exit 0
fi

nmcli radio wifi on || true
nmcli -w "${UP_WAIT_SEC}" connection up "${WIFI_CON}" || true
