#!/bin/bash
# ExecStopPost: park Wi-Fi if eth still has carrier; otherwise raise Wi-Fi.
# Official: https://www.networkmanager.dev/docs/api/latest/nmcli.html
#           https://manpages.debian.org/bookworm/systemd/systemd.service.5.en.html
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
