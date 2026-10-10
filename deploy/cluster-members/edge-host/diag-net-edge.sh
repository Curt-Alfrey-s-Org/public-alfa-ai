#!/bin/bash
# Read-only network diagnosis for Pi5 (edge): why Wi-Fi did not take over.
export LC_ALL=C

echo "=== uptime ==="
uptime -p

echo "=== links ==="
ip -brief link
echo "eth0 carrier: $(cat /sys/class/net/eth0/carrier 2>/dev/null)"
echo "wlan0 operstate: $(cat /sys/class/net/wlan0/operstate 2>/dev/null)"

echo "=== nmcli ==="
nmcli radio
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status

echo "=== dispatcher dir ==="
ls -l /etc/NetworkManager/dispatcher.d/

echo "=== dispatcher service ==="
systemctl is-enabled NetworkManager-dispatcher.service 2>&1
systemctl is-active NetworkManager-dispatcher.service 2>&1

echo "=== journal: dispatcher runs (last 200 NM lines) ==="
journalctl -b --no-pager -u NetworkManager -u NetworkManager-dispatcher -n 200 \
  | grep -Ei 'dispatch|wifi|wlan|carrier|rfkill|radio|70-wifi|eth0' \
  | tail -70

echo "=== journal: nm-dispatcher only ==="
journalctl -b --no-pager -t nm-dispatcher -n 40

echo "=== NM state ==="
cat /var/lib/NetworkManager/NetworkManager.state
