#!/usr/bin/env bash
# Ensure /mnt/z in WSL points at the Windows Z: HF hub (\\hub\huggingface).
# Network drive letters are not auto-visible in WSL; drvfs bind is required.
#
# Run inside WSL (deploy calls this before compose when using WSL Docker):
#   bash deploy/cluster-members/_common/ensure-wsl-smb-hf-mount.sh
set -euo pipefail

MOUNT_POINT=/mnt/z

if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
  echo "OK: $MOUNT_POINT already mounted"
  exit 0
fi

if [[ ! -d /mnt/z ]] && [[ ! -e /mnt/z ]]; then
  sudo mkdir -p "$MOUNT_POINT"
fi

# Z: must be mapped in Windows first (net use Z: \\hub\huggingface).
if ! cmd.exe /c 'if exist Z:\hub (echo OK) else (echo MISSING)' 2>/dev/null | grep -q OK; then
  echo "ERROR: Windows Z: hub not reachable. Run: net use Z: \\\\hub\\huggingface /PERSISTENT:YES" >&2
  exit 1
fi

sudo mount -t drvfs Z: "$MOUNT_POINT" 2>/dev/null || sudo mount -t drvfs 'Z:\' "$MOUNT_POINT"

if [[ -d "$MOUNT_POINT/hub" ]] || [[ -d "$MOUNT_POINT" ]]; then
  echo "OK: drvfs mounted Z: -> $MOUNT_POINT"
  exit 0
fi

echo "ERROR: $MOUNT_POINT mounted but hub layout not found" >&2
exit 1
