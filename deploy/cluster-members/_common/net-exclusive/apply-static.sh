#!/bin/bash
# Static IPv4 on both wired and Wi-Fi profiles. Does not nmcli connection down
# (that blocks autoconnect: https://www.networkmanager.dev/docs/api/latest/nmcli.html).
set -euo pipefail
export LC_ALL=C

[ -r /etc/default/alfa-net-exclusive ] && . /etc/default/alfa-net-exclusive

ETH_DEV=${ETH_DEV:-eth0}
WIFI_DEV=${WIFI_DEV:-wlan0}
ETH_CON=${ETH_CON:-"Wired connection 1"}
WIFI_CON=${WIFI_CON:-StarWarz2}
ADDR=${ADDR:-orchestrator/24}
GW=${GW:-orchestrator}
DNS=${DNS:-orchestrator}

nmcli connection modify "$ETH_CON" \
  ipv4.method manual \
  ipv4.addresses "$ADDR" \
  ipv4.gateway "$GW" \
  ipv4.dns "$DNS" \
  ipv4.route-metric 100 \
  connection.autoconnect yes

nmcli connection modify "$WIFI_CON" \
  ipv4.method manual \
  ipv4.addresses "$ADDR" \
  ipv4.gateway "$GW" \
  ipv4.dns "$DNS" \
  ipv4.route-metric 600 \
  connection.autoconnect yes

if [ -n "${EXTRA_WIFI_CON:-}" ] && [ "$EXTRA_WIFI_CON" != "$WIFI_CON" ]; then
    nmcli connection modify "$EXTRA_WIFI_CON" connection.autoconnect no || true
fi

if [ "$(cat "/sys/class/net/${ETH_DEV}/carrier" 2>/dev/null || echo 0)" = "1" ]; then
    nmcli device reapply "$ETH_DEV" || nmcli connection up "$ETH_CON"
fi
if nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -qx "${WIFI_DEV}:connected"; then
    nmcli device reapply "$WIFI_DEV" || nmcli connection up "$WIFI_CON"
fi

echo "=== verify ==="
nmcli -f ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.route-metric connection show "$ETH_CON"
nmcli -f ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.route-metric connection show "$WIFI_CON"
ip -brief addr
ip route
