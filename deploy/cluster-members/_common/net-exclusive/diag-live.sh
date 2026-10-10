#!/bin/bash
export LC_ALL=C
echo "=== host ==="
hostname
echo "=== devices ==="
nmcli -t -f DEVICE,STATE,CONNECTION device status | grep -E '^(eth0|wlan0):'
echo "=== addr ==="
ip -brief addr show dev eth0
ip -brief addr show dev wlan0
echo "eth carrier: $(cat /sys/class/net/eth0/carrier 2>/dev/null || echo none)"
echo "=== radio ==="
nmcli radio wifi
echo "=== unit ==="
systemctl is-active alfa-net-exclusive.service
systemctl is-enabled alfa-net-exclusive.service
echo "=== defaults ==="
cat /etc/default/alfa-net-exclusive 2>/dev/null || echo NO_DEFAULT
echo "=== stop helper ==="
grep ExecStopPost /etc/systemd/system/alfa-net-exclusive.service 2>/dev/null
echo "=== route ==="
ip route | head -5
