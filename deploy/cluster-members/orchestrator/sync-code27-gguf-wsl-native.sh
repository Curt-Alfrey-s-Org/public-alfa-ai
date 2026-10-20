#!/usr/bin/env bash
# Copy Code27 GGUF from /mnt/c (Drvfs) to WSL ext4 for faster coordinator reads.
# Drvfs mmap/read is slow for 16 GB RPC tensor streaming; ext4 avoids that path.
#
# Usage (on orchestrator via WSL):
#   bash deploy/cluster-members/orchestrator/sync-code27-gguf-wsl-native.sh
#
set -euo pipefail

SRC="${CODE27_GGUF_SRC:-/mnt/c/alfa-ai-cache/llama-cpp/models/Qwen3.6-27B-UD-Q4_K_XL.gguf}"
DEST_DIR="${CODE27_MODELS_DIR:-$HOME/alfa-ai-cache/llama-cpp/models}"
DEST="$DEST_DIR/${inference_MODEL_FILE:-Qwen3.6-27B-UD-Q4_K_XL.gguf}"
MIN_BYTES=15000000000

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: missing hub copy at $SRC" >&2
  echo "  Run sync-frontier-code-gguf-from-hub.ps1 on orchestrator first." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
src_size=$(stat -c%s "$SRC")
if [[ -f "$DEST" ]]; then
  dest_size=$(stat -c%s "$DEST")
  if [[ "$dest_size" -ge "$MIN_BYTES" && "$dest_size" -eq "$src_size" ]]; then
    echo "Code27 GGUF already on WSL ext4: $DEST ($dest_size bytes)"
    exit 0
  fi
  echo "Replacing stale WSL copy ($dest_size bytes)..."
  rm -f "$DEST"
fi

echo "Copying Code27 GGUF to WSL ext4 (one-time, ~16 GB)..."
echo "  $SRC -> $DEST"
cp -v "$SRC" "$DEST"
echo "Done: $(stat -c%s "$DEST") bytes at $DEST"
