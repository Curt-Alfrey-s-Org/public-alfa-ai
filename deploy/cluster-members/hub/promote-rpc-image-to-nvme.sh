#!/usr/bin/env bash
# Permanent hub fast path: keep RPC tarball on NVMe (or SSD) for docker load.
#
# Canonical seed stays on HDD. Hot copy is preferred by
# ensure-rpc-image-local-cache.sh / load-llamacpp-rpc-from-hub.sh.
# Safe to re-run (no-op when already present unless FORCE=1).
#
# Usage (operator on hub):
#   sudo bash deploy/cluster-members/hub/promote-rpc-image-to-nvme.sh
#   sudo FORCE=1 bash .../promote-rpc-image-to-nvme.sh
#
# After copy (and on already-present): POSIX other-read (root umask 0640).
# Docs: docs/HUB_ARTIFACTS.md
set -euo pipefail

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_common" && pwd)"

TARBALL="${ALFA_RPC_TARBALL:-alfa-llamacpp-rpc-cuda128-b10355.tar.gz}"
SRC_DIR='/mnt/hub/alfa-ai/docker-images'
SRC="$SRC_DIR/$TARBALL"

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: missing canonical $SRC" >&2
  exit 1
fi

DEST_DIR=""
for cand in /mnt/nvme/Alfa-AI/docker-images /mnt/ssd/Alfa-AI/docker-images; do
  base="$(dirname "$cand")"
  # Parent pool mount must exist (/mnt/nvme or /mnt/ssd).
  if [[ ! -d "$(dirname "$base")" ]]; then
    continue
  fi
  if mkdir -p "$cand" 2>/dev/null && [[ -w "$cand" ]]; then
    DEST_DIR="$cand"
    break
  fi
done

if [[ -z "$DEST_DIR" ]]; then
  echo "ERROR: neither /mnt/nvme nor /mnt/ssd available for hot docker-images" >&2
  echo "  Create dataset per docs/hub_111_NVME_POOL.md then re-run" >&2
  exit 1
fi

DEST="$DEST_DIR/$TARBALL"
if [[ -f "$DEST" && "${FORCE:-0}" != "1" ]]; then
  echo "OK: already present $DEST ($(du -h "$DEST" | awk '{print $1}'))"
  bash "$COMMON/ensure-posix-other-read.sh" "$DEST_DIR" "$DEST"
  if [[ -f "$DEST_DIR/images.json" ]]; then
    bash "$COMMON/ensure-posix-other-read.sh" "$DEST_DIR/images.json"
  fi
  exit 0
fi

echo "== promote $SRC -> $DEST =="
cp -f "$SRC" "$DEST.tmp"
mv -f "$DEST.tmp" "$DEST"
if [[ -f "$SRC_DIR/images.json" ]]; then
  cp -f "$SRC_DIR/images.json" "$DEST_DIR/images.json"
fi
bash "$COMMON/ensure-posix-other-read.sh" "$DEST_DIR" "$DEST"
if [[ -f "$DEST_DIR/images.json" ]]; then
  bash "$COMMON/ensure-posix-other-read.sh" "$DEST_DIR/images.json"
fi
echo "OK: $DEST ($(du -h "$DEST" | awk '{print $1}'))"
echo "  load-llamacpp-rpc-from-hub.sh prefers this path over HDD"
