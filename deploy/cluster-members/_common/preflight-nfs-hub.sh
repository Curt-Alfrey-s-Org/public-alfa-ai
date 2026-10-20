#!/usr/bin/env bash
# Ensure /mnt/cluster NFS hub is mounted and responsive before hub-backed deploy steps.
#
# Usage:
#   bash deploy/cluster-members/_common/preflight-nfs-hub.sh
#
# Env:
#   ALFA_REPO_DIR or ALFA_AI_REPO  - alfa-ai checkout (default: three levels up from _common)
#   NFS_HUB_OPTIONAL=1             - warn and exit 0 if mount fails (default: fail hard)
#   hub_IP, NFS_REMOTE, LOCAL_MOUNT - passed through to mount_nfs_models.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-${ALFA_AI_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd)}}"
LOCAL_MOUNT="${LOCAL_MOUNT:-/mnt/cluster}"
PROBE_PATH="${NFS_HUB_PROBE_PATH:-$LOCAL_MOUNT/docker-images}"

if [[ ! -x "$REPO_DIR/scripts/mount_nfs_models.sh" ]]; then
  echo "ERROR: missing $REPO_DIR/scripts/mount_nfs_models.sh" >&2
  exit 1
fi

hub_responsive() {
  mountpoint -q "$LOCAL_MOUNT" 2>/dev/null \
    && timeout 5 test -d "$PROBE_PATH" 2>/dev/null
}

echo "== preflight-nfs-hub: $LOCAL_MOUNT =="

if hub_responsive; then
  findmnt "$LOCAL_MOUNT" 2>/dev/null | sed 's/^/  /' || true
  echo "preflight-nfs-hub OK (responsive)"
  exit 0
fi

if mountpoint -q "$LOCAL_MOUNT" 2>/dev/null; then
  echo "WARN: $LOCAL_MOUNT mountpoint stale; remounting..." >&2
  sudo umount -l "$LOCAL_MOUNT" 2>/dev/null || true
fi

if ! (cd "$REPO_DIR" && bash scripts/mount_nfs_models.sh); then
  if [[ "${NFS_HUB_OPTIONAL:-}" == "1" ]]; then
    echo "WARN: NFS hub mount failed (NFS_HUB_OPTIONAL=1; continuing)" >&2
    exit 0
  fi
  echo "ERROR: NFS hub mount failed; run: cd $REPO_DIR && bash scripts/mount_nfs_models.sh" >&2
  exit 1
fi

if ! hub_responsive; then
  if [[ "${NFS_HUB_OPTIONAL:-}" == "1" ]]; then
    echo "WARN: $LOCAL_MOUNT not responsive after mount (NFS_HUB_OPTIONAL=1)" >&2
    exit 0
  fi
  echo "ERROR: $LOCAL_MOUNT mounted but $PROBE_PATH not reachable" >&2
  exit 1
fi

findmnt "$LOCAL_MOUNT" 2>/dev/null | sed 's/^/  /' || true
echo "preflight-nfs-hub OK"
