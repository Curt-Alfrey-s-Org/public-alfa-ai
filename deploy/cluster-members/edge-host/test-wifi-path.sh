#!/bin/bash
# Prove the Wi-Fi bring-up path (radio on -> associate -> static IPv4) works
# while the cable is still plugged in, using a scratch address so edge is never
# claimed by two interfaces at once. Restores edge and the watchdog on exit.
set -uo pipefail
export LC_ALL=C

WIFI_CON=${WIFI_CON:-StarWarz2}
SCRATCH=${SCRATCH:-orchestrator/24}
REAL=${REAL:-orchestrator/24}

restore() {
    echo "=== restore ==="
    nmcli radio wifi off || true
    nmcli connection modify "$WIFI_CON" ipv4.addresses "$REAL"
    nmcli -f ipv4.addresses connection show "$WIFI_CON"
    systemctl start alfa-net-exclusive.service
    systemctl is-active alfa-net-exclusive.service
}
trap restore EXIT

systemctl stop alfa-net-exclusive.service

echo "=== scratch address ==="
nmcli connection modify "$WIFI_CON" ipv4.addresses "$SCRATCH"

echo "=== radio on + activate ==="
nmcli radio wifi on
sleep 2
nmcli -w 40 connection up "$WIFI_CON"

echo "=== result ==="
nmcli -t -f DEVICE,STATE,CONNECTION device status | grep -E '^(eth0|wlan0):'
ip -brief addr show dev wlan0
ip route
