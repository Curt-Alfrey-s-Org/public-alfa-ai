#!/bin/bash
export LC_ALL=C
echo "=== host ==="
hostname
hostname -I
cat /proc/device-tree/model 2>/dev/null; echo
echo "=== links ==="
ip -brief link
ip -brief addr
echo "eth carrier: $(cat /sys/class/net/eth0/carrier 2>/dev/null || echo none)"
echo "wlan oper: $(cat /sys/class/net/wlan0/operstate 2>/dev/null || echo none)"
echo "=== route ==="
ip route
echo "=== nmcli radio ==="
nmcli radio
echo "=== devices ==="
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
echo "=== connections ==="
nmcli -t -f NAME,UUID,TYPE,DEVICE,AUTOCONNECT connection show
echo "=== wired ipv4 ==="
nmcli -f connection.id,ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.route-metric,connection.autoconnect connection show "Wired connection 1" 2>/dev/null || true
echo "=== wifi profiles ==="
nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="802-11-wireless"{print $1}'
echo "=== dispatcher ==="
ls -l /etc/NetworkManager/dispatcher.d/ 2>/dev/null
echo "=== units ==="
systemctl is-enabled alfa-net-exclusive.service 2>&1
systemctl is-active alfa-net-exclusive.service 2>&1
systemctl is-enabled wifi-failover-monitor.service 2>&1
systemctl is-active wifi-failover-monitor.service 2>&1
ls /etc/systemd/system/*wifi* /etc/systemd/system/*exclusive* /usr/local/sbin/alfa-net* 2>/dev/null
echo "=== NM state ==="
sudo cat /var/lib/NetworkManager/NetworkManager.state 2>/dev/null
echo "=== macs ==="
echo "eth0 $(cat /sys/class/net/eth0/address 2>/dev/null)"
echo "wlan0 $(cat /sys/class/net/wlan0/address 2>/dev/null)"
