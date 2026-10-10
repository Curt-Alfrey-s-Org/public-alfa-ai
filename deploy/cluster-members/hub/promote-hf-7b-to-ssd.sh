#!/usr/bin/env bash
# Permanent hub fast path: hot-copy Qwen2.5-Coder-7B-Instruct HF cache to SSD.
# Canonical (archive): /mnt/hub/alfa-ai/models/huggingface/hub/
# Hot (train read):    /mnt/ssd/Alfa-AI/models/huggingface/hub/
#   (or /mnt/nvme/... if that pool exists)
#
# Train island Start binds HF_HOME from NFS /mnt/cluster-ssd (this tree), not HDD
# /mnt/cluster. Do not download from huggingface.co on workers.
#
# Usage (operator on hub):
#   sudo bash deploy/cluster-members/hub/promote-hf-7b-to-ssd.sh
#   sudo FORCE=1 bash .../promote-hf-7b-to-ssd.sh
#
# rsync(1): https://man7.org/linux/man-pages/man1/rsync.1.html
# chmod(1) a+rX: https://man7.org/linux/man-pages/man1/chmod.1.html
# HF cache layout: https://huggingface.co/docs/huggingface_hub/guides/manage-cache
# Docs: docs/HUB_ARTIFACTS.md, docs/operations/TRAIN_7B_QLORA_GUI.md
set -euo pipefail

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_common" && pwd)"

REPO_DIR='models--Qwen--Qwen2.5-Coder-7B-Instruct'
SRC_HUB='/mnt/hub/alfa-ai/models/huggingface/hub'
SRC="$SRC_HUB/$REPO_DIR"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: missing canonical HF cache $SRC" >&2
  echo "  Seed on hub first (hub_hub_models.sh / hub-first). Do not download on workers." >&2
  exit 1
fi

DEST_HUB=""
HOT_ROOT=""
for pool in /mnt/nvme /mnt/ssd; do
  if [[ ! -d "$pool" ]]; then
    continue
  fi
  cand="$pool/Alfa-AI/models/huggingface/hub"
  if mkdir -p "$cand" 2>/dev/null && [[ -w "$cand" ]]; then
    DEST_HUB="$cand"
    HOT_ROOT="$pool/Alfa-AI"
    break
  fi
done

if [[ -z "$DEST_HUB" || -z "$HOT_ROOT" ]]; then
  echo "ERROR: neither /mnt/nvme nor /mnt/ssd available for hot HF cache" >&2
  exit 1
fi

DEST="$DEST_HUB/$REPO_DIR"

need_bytes=20000000000
if [[ -d "$DEST" && "${FORCE:-0}" != "1" ]]; then
  if find "$DEST/snapshots" -name config.json -print -quit 2>/dev/null | grep -q .; then
    echo "OK: snapshot already present under $DEST"
    echo "    rsync -a to catch missing blobs (no --delete)"
  fi
else
  avail="$(df -B1 --output=avail "$HOT_ROOT" | tail -n 1 | tr -d ' ')"
  if [[ -n "$avail" && "$avail" -lt "$need_bytes" ]]; then
    echo "ERROR: need ~20 GB free on SSD/NVMe for first 7B promote; avail=$avail bytes" >&2
    df -h "$HOT_ROOT" >&2
    exit 1
  fi
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "ERROR: rsync not found (required for HF cache tree)" >&2
  exit 1
fi

echo "== promote HF $SRC -> $DEST =="
mkdir -p "$DEST"
rsync -a "$SRC/" "$DEST/"
chmod -R a+rX "$DEST_HUB"
bash "$COMMON/ensure-posix-other-read.sh" "$DEST_HUB" "$DEST"
# huggingface_hub creates <cache>/.locks for concurrent access
# https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache
# chmod a+rX is not enough: NFS Maproot operator must create lock files.
mkdir -p "$DEST_HUB/.locks"
chmod a+rwx "$DEST_HUB" "$DEST_HUB/.locks"
if ! touch "$DEST_HUB/.locks/.alfa-write-test"; then
  echo "ERROR: cannot write $DEST_HUB/.locks (needed for HF cache locks)" >&2
  ls -lad "$DEST_HUB" "$DEST_HUB/.locks" >&2
  exit 1
fi
rm -f "$DEST_HUB/.locks/.alfa-write-test"
if ! find "$DEST/snapshots" -name config.json -print -quit 2>/dev/null | grep -q .; then
  echo "ERROR: no config.json under $DEST/snapshots after rsync" >&2
  exit 1
fi
echo "OK: $DEST ($(du -sh "$DEST" | awk '{print $1}'))"
echo "  NFS clients: mount hub:${HOT_ROOT} at /mnt/cluster-ssd"
echo "  Then HF_HOME is /mnt/cluster-ssd/models/huggingface"
echo "  hub must export ${HOT_ROOT} (Shares -> Unix NFS; not pool root /mnt/ssd)."
echo "  Official: https://www.hub.com/docs/scale/shares/nfs/addingnfsshares/"
