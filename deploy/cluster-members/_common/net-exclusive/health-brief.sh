#!/bin/bash
export LC_ALL=C
echo "hostname=$(hostname)"
echo "eth_carrier=$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo none)"
echo "wlan_oper=$(cat /sys/class/net/wlan0/operstate 2>/dev/null || echo none)"
nmcli -t -f DEVICE,STATE,CONNECTION device status | grep -E '^(eth0|wlan0):'
ip -brief addr show dev eth0
ip -brief addr show dev wlan0
echo "wifi_radio=$(nmcli -t radio wifi)"
echo "unit=$(systemctl is-active alfa-net-exclusive.service 2>/dev/null) $(systemctl is-enabled alfa-net-exclusive.service 2>/dev/null)"
test -f /etc/default/alfa-net-exclusive && echo "defaults=yes" || echo "defaults=NO"
echo "stop=$(grep -E '^ExecStopPost' /etc/systemd/system/alfa-net-exclusive.service 2>/dev/null || echo missing)"
echo "gw=$(ip route | awk '/^default/{print $0; exit}')"
ping -c 1 -W 2 orchestrator >/dev/null 2>&1 && echo "gw_ping=ok" || echo "gw_ping=FAIL"
echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"
echo "uptime=$(uptime -p)"
