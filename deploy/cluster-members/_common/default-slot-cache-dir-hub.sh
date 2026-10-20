#!/usr/bin/env bash
# Default SLOT_CACHE_DIR for hub llama.cpp coordinator (--slot-save-path bind mount).
# Fast tier: /mnt/nvme|ssd/Alfa-AI/llama-cpp/slot-cache-111 (same Alfa-AI case as
# promote-gguf-to-ssd.sh). Fallback: the HDD repo clone.
#
# A pool root must be a real mountpoint (or already carry the Alfa-AI tree)
# before we create anything under it. An exported pool leaves an empty
# /mnt/<pool> directory behind, and writing there would silently land the cache
# on the boot filesystem instead of falling back to HDD.
#
# Runs as root in the deploy path (coordinator scripts call the write-grev*
# env writers via `sudo bash`), so mkdir under /mnt/ssd succeeds.
#
# Usage:
#   default="$(bash default-slot-cache-dir-111.sh "$REPO_DIR")"
#   export SLOT_CACHE_DIR="${SLOT_CACHE_DIR:-$default}"
set -euo pipefail

REPO_DIR="${1:-/mnt/hub/alfa-ai/repo/alfa-ai}"
HDD_FALLBACK="$REPO_DIR/deploy/llamacpp-rpc/slot-cache-111"

for cand in \
  /mnt/nvme/Alfa-AI/llama-cpp/slot-cache-111 \
  /mnt/ssd/Alfa-AI/llama-cpp/slot-cache-111
do
  base="$(dirname "$(dirname "$cand")")"
  pool_root="$(dirname "$base")"
  if [[ ! -d "$pool_root" ]]; then
    continue
  fi
  # Empty leftover mountpoint: skip unless the pool is actually mounted.
  if ! mountpoint -q "$pool_root" 2>/dev/null && [[ ! -d "$base" ]]; then
    continue
  fi
  if mkdir -p "$cand" 2>/dev/null && [[ -w "$cand" ]]; then
    echo "$cand"
    exit 0
  fi
done

echo "WARN: no nvme/ssd fast tier for slot cache; using HDD fallback $HDD_FALLBACK" >&2
mkdir -p "$HDD_FALLBACK" 2>/dev/null || true
echo "$HDD_FALLBACK"
