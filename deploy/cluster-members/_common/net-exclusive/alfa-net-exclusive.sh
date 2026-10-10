#!/bin/bash
# Keep one static LAN address on whichever uplink is live (eth0 vs wlan0).
# Host values: /etc/default/alfa-net-exclusive
# Official: https://www.networkmanager.dev/docs/api/latest/nmcli.html
#           https://networkmanager.dev/docs/rfkill/
#           https://www.networkmanager.dev/docs/api/latest/NetworkManager-dispatcher.html
set -uo pipefail
export LC_ALL=C

[ -r /etc/default/alfa-net-exclusive ] && . /etc/default/alfa-net-exclusive

ETH_DEV=${ETH_DEV:-eth0}
WIFI_DEV=${WIFI_DEV:-wlan0}
WIFI_CON=${WIFI_CON:-StarWarz2}
POLL_SEC=${POLL_SEC:-5}
UP_WAIT_SEC=${UP_WAIT_SEC:-30}

log() { echo "alfa-net-exclusive: $*"; }

wired_carrier() {
    cat "/sys/class/net/${ETH_DEV}/carrier" 2>/dev/null || echo 0
}

wifi_radio_on() { [ "$(nmcli -t radio wifi 2>/dev/null)" = "enabled" ]; }

wifi_connected() {
    nmcli -t -f DEVICE,STATE device status 2>/dev/null \
        | grep -qx "${WIFI_DEV}:connected"
}

park_wifi() {
    if wifi_radio_on; then
        log "wired carrier present - disabling Wi-Fi radio"
        nmcli radio wifi off
    fi
}

raise_wifi() {
    if ! wifi_radio_on; then
        log "wired carrier absent - enabling Wi-Fi radio"
        nmcli radio wifi on
        sleep 2
    fi
    if ! wifi_connected; then
        log "activating Wi-Fi profile ${WIFI_CON}"
        nmcli -w "${UP_WAIT_SEC}" connection up "${WIFI_CON}" || true
    fi
}

while true; do
    if [ "$(wired_carrier)" = "1" ]; then
        park_wifi
    else
        raise_wifi
    fi
    sleep "${POLL_SEC}"
done
