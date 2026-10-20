#!/usr/bin/env bash
# One-time: install systemd units so /mnt/cluster auto-mounts on boot and recovers from stale NFS.
#
# Run on each Linux cluster member that uses /mnt/cluster ( pool-opt-in, apps, inference ).
# Idempotent. Requires sudo.
#
# Usage:
#   cd ~/alfa-ai && bash scripts/install-nfs-hub-systemd.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
UNIT_DIR="$REPO_DIR/deploy/systemd"

for unit in alfa-nfs-hub-mount.service alfa-nfs-hub-watch.service alfa-nfs-hub-watch.timer; do
  if [[ ! -f "$UNIT_DIR/$unit" ]]; then
    echo "ERROR: missing $UNIT_DIR/$unit" >&2
    exit 1
  fi
done

echo "== NFS hub one-time mount (fstab) =="
bash "$REPO_DIR/scripts/mount_nfs_models.sh"

echo "== Installing systemd units =="
sudo cp "$UNIT_DIR/alfa-nfs-hub-mount.service" /etc/systemd/system/
sudo cp "$UNIT_DIR/alfa-nfs-hub-watch.service" /etc/systemd/system/
sudo cp "$UNIT_DIR/alfa-nfs-hub-watch.timer" /etc/systemd/system/

sudo sed -i "s|@ALFA_REPO_DIR@|$REPO_DIR|g" /etc/systemd/system/alfa-nfs-hub-mount.service
sudo sed -i "s|@ALFA_REPO_DIR@|$REPO_DIR|g" /etc/systemd/system/alfa-nfs-hub-watch.service

sudo systemctl daemon-reload
sudo systemctl enable alfa-nfs-hub-mount.service
sudo systemctl enable alfa-nfs-hub-watch.timer
sudo systemctl start alfa-nfs-hub-mount.service
sudo systemctl start alfa-nfs-hub-watch.timer

echo ""
echo "== Installed =="
systemctl is-active alfa-nfs-hub-mount.service || true
systemctl is-active alfa-nfs-hub-watch.timer || true
echo "  mount:  systemctl status alfa-nfs-hub-mount.service"
echo "  watch:  systemctl list-timers alfa-nfs-hub-watch.timer"
