#!/bin/bash
# Install alfa-net-exclusive. SRC = directory of .sh/.service.
# DEFAULT_FILE = host defaults copied to /etc/default/alfa-net-exclusive.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HERE}
DEFAULT_FILE=${DEFAULT_FILE:-$SRC/alfa-net-exclusive.default}
DISPATCHER=/etc/NetworkManager/dispatcher.d/70-wifi-wired-exclusive.sh

if [ -e "$DISPATCHER" ]; then
    echo "removing $DISPATCHER (replaced by alfa-net-exclusive.service)"
    rm -f "$DISPATCHER"
fi

if [ -f "$DEFAULT_FILE" ]; then
    install -m 0644 -o root -g root "$DEFAULT_FILE" /etc/default/alfa-net-exclusive
fi

install -m 0755 -o root -g root "${SRC}/alfa-net-exclusive.sh" /usr/local/sbin/alfa-net-exclusive.sh
install -m 0755 -o root -g root "${SRC}/alfa-net-exclusive-stop.sh" /usr/local/sbin/alfa-net-exclusive-stop.sh
install -m 0644 -o root -g root "${SRC}/alfa-net-exclusive.service" /etc/systemd/system/alfa-net-exclusive.service

systemctl daemon-reload
systemctl enable --now alfa-net-exclusive.service
systemctl restart alfa-net-exclusive.service

echo "=== unit ==="
systemctl is-enabled alfa-net-exclusive.service
systemctl is-active alfa-net-exclusive.service
echo "=== defaults ==="
cat /etc/default/alfa-net-exclusive
