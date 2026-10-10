#!/bin/bash
# Simulate loss of wired carrier and let alfa-net-exclusive.service move
# orchestrator to Wi-Fi. A systemd timer restores the wired link after
# RESTORE_SEC no matter what happens, so a failed failover cannot strand a
# headless board.
set -uo pipefail
export LC_ALL=C

ETH_DEV=${ETH_DEV:-eth0}
ETH_CON=${ETH_CON:-Wired connection 1}
RESTORE_SEC=${RESTORE_SEC:-90}

echo "=== arming restore in ${RESTORE_SEC}s ==="
systemd-run --on-active="${RESTORE_SEC}" --unit=alfa-eth-restore \
    /bin/bash -c "ip link set ${ETH_DEV} up; nmcli connection up '${ETH_CON}'"

echo "=== dropping ${ETH_DEV} ==="
ip link set "${ETH_DEV}" down

sleep 25

echo "=== state after failover window ==="
nmcli -t -f DEVICE,STATE,CONNECTION device status | grep -E "^(${ETH_DEV}|wlan0):"
ip -brief addr show dev wlan0
ip route
nmcli radio wifi
