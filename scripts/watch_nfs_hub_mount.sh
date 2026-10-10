#!/usr/bin/env bash
# systemd helper: remount /mnt/cluster when autofs/NFS is stale after a network flap.
#
# Usage:
#   bash scripts/watch_nfs_hub_mount.sh
# Install timer: bash scripts/install-nfs-hub-systemd.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOCAL_MOUNT="${LOCAL_MOUNT:-/mnt/cluster}"
PROBE_PATH="${NFS_HUB_PROBE_PATH:-$LOCAL_MOUNT/docker-images}"

if mountpoint -q "$LOCAL_MOUNT" 2>/dev/null \
    && timeout 5 test -d "$PROBE_PATH" 2>/dev/null; then
  exit 0
fi

exec bash "$REPO_DIR/deploy/cluster-members/_common/preflight-nfs-hub.sh"
