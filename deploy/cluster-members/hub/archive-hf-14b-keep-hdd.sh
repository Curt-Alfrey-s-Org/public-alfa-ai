#!/usr/bin/env bash
# Archive Qwen2.5-Coder-14B-Instruct on hub HDD. Do not Start 14B train.
#
# Canonical keep: /mnt/hub/alfa-ai/models/huggingface/hub/models--Qwen--Qwen2.5-Coder-14B-Instruct
# Optional: remove the SSD/NVMe hot copy so 14B does not occupy fast-tier space.
# Never deletes the HDD tree.
#
# Usage (operator on hub):
#   sudo bash deploy/cluster-members/hub/archive-hf-14b-keep-hdd.sh
#   sudo CONFIRM=1 bash deploy/cluster-members/hub/archive-hf-14b-keep-hdd.sh
#
# CONFIRM=1 required before rm of SSD/NVMe copy.
# rsync(1): https://man7.org/linux/man-pages/man1/rsync.1.html
# rm(1): https://man7.org/linux/man-pages/man1/rm.1.html
# HF cache: https://huggingface.co/docs/huggingface_hub/guides/manage-cache
# Docs: docs/HUB_ARTIFACTS.md, docs/operations/TRAIN_7B_QLORA_GUI.md
set -euo pipefail

REPO_DIR='models--Qwen--Qwen2.5-Coder-14B-Instruct'
SRC_HUB='/mnt/hub/alfa-ai/models/huggingface/hub'
SRC="$SRC_HUB/$REPO_DIR"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: missing HDD archive $SRC -- will not remove any SSD copy" >&2
  echo "  Seed on hub first. Do not download 14B on workers." >&2
  exit 1
fi
if ! find "$SRC/snapshots" -name config.json -print -quit 2>/dev/null | grep -q .; then
  echo "ERROR: no config.json under $SRC/snapshots -- abort (keep SSD copy)" >&2
  exit 1
fi

echo "OK: HDD archive $SRC ($(du -sh "$SRC" | awk '{print $1}'))"

removed=0
for pool in /mnt/ssd /mnt/nvme; do
  dest="$pool/Alfa-AI/models/huggingface/hub/$REPO_DIR"
  if [[ ! -d "$dest" ]]; then
    continue
  fi
  echo "Found hot copy: $dest ($(du -sh "$dest" | awk '{print $1}'))"
  if [[ "${CONFIRM:-0}" != "1" ]]; then
    echo "  Dry run: set CONFIRM=1 to remove this SSD/NVMe copy. HDD stays."
    continue
  fi
  echo "== rm -rf $dest (HDD archive kept) =="
  rm -rf "$dest"
  removed=1
  echo "OK: removed $dest"
done

if [[ "${CONFIRM:-0}" != "1" ]]; then
  echo "No files removed. Re-run with CONFIRM=1 to drop SSD/NVMe 14B copies only."
  exit 0
fi
if [[ "$removed" -eq 0 ]]; then
  echo "OK: no SSD/NVMe 14B tree present. HDD archive only."
fi
echo "Do not GUI-Start 14B. Do not promote-hf-14b-to-ssd.sh unless un-archiving."
