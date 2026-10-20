#!/usr/bin/env bash
# Permanent hub fast path: hot-copy active 27B GGUF to SSD (spinning HDD = archive only).
#
# Canonical: /mnt/hub/alfa-ai/llama-cpp/models/
# Hot:       /mnt/ssd/Alfa-AI/llama-cpp/models/  (or /mnt/nvme/... if present)
#
# write-grev27-pool-env.sh prefers the hot path when the file exists there.
# Safe to re-run (no-op unless FORCE=1 or sizes differ).
#
# Usage (operator on hub):
#   sudo bash deploy/cluster-members/hub/promote-gguf-to-ssd.sh
#   sudo FORCE=1 bash .../promote-gguf-to-ssd.sh
#
# After copy (and on already-present files): POSIX other-read. sudo cp inherits
# root umask 0640; coordinator bind-mounts that mode.
# Docs: docs/HUB_ARTIFACTS.md
set -euo pipefail

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_common" && pwd)"

MODEL_FILE="${inference_MODEL_FILE:-Qwen3.8-27B-Q8_0.gguf}"
SRC_DIR='/mnt/hub/alfa-ai/llama-cpp/models'
SRC="$SRC_DIR/$MODEL_FILE"

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: missing canonical GGUF $SRC" >&2
  exit 1
fi

DEST_DIR=""
for cand in /mnt/nvme/Alfa-AI/llama-cpp/models /mnt/ssd/Alfa-AI/llama-cpp/models; do
  base="$(dirname "$(dirname "$cand")")"
  if [[ ! -d "$(dirname "$base")" ]]; then
    continue
  fi
  if mkdir -p "$cand" 2>/dev/null && [[ -w "$cand" ]]; then
    DEST_DIR="$cand"
    break
  fi
done

if [[ -z "$DEST_DIR" ]]; then
  echo "ERROR: neither /mnt/nvme nor /mnt/ssd available for hot GGUF" >&2
  exit 1
fi

DEST="$DEST_DIR/$MODEL_FILE"

# Split GGUF (lead *-00001-of-NNNNN.gguf): promote every sibling shard.
promote_one() {
  local src_file="$1"
  local dest_file="$2"
  mkdir -p "$(dirname "$dest_file")"
  if [[ -f "$dest_file" && "${FORCE:-0}" != "1" ]]; then
    local src_sz dst_sz
    src_sz="$(stat -c %s "$src_file" 2>/dev/null || stat -f %z "$src_file")"
    dst_sz="$(stat -c %s "$dest_file" 2>/dev/null || stat -f %z "$dest_file")"
    if [[ "$src_sz" == "$dst_sz" ]]; then
      echo "OK: already present $dest_file ($(du -h "$dest_file" | awk '{print $1}'))"
      bash "$COMMON/ensure-posix-other-read.sh" "$(dirname "$dest_file")" "$dest_file"
      return 0
    fi
    echo "WARN: size mismatch hub vs hot; refreshing $dest_file"
  fi
  echo "== promote GGUF $src_file -> $dest_file =="
  cp -f "$src_file" "${dest_file}.tmp"
  mv -f "${dest_file}.tmp" "$dest_file"
  bash "$COMMON/ensure-posix-other-read.sh" "$(dirname "$dest_file")" "$dest_file"
  echo "OK: $dest_file ($(du -h "$dest_file" | awk '{print $1}'))"
}

if [[ "$MODEL_FILE" =~ ^(.*)-00001-of-([0-9]+)\.gguf$ ]]; then
  prefix="${BASH_REMATCH[1]}"
  total=$((10#${BASH_REMATCH[2]}))
  echo "== promote split GGUF ($total shards) prefix=$prefix =="
  for ((i = 1; i <= total; i++)); do
    printf -v shard '%s-%05d-of-%05d.gguf' "$prefix" "$i" "$total"
    if [[ ! -f "$SRC_DIR/$shard" ]]; then
      echo "ERROR: missing hub shard $SRC_DIR/$shard" >&2
      exit 1
    fi
    promote_one "$SRC_DIR/$shard" "$DEST_DIR/$shard"
  done
  echo "Coordinator MODELS_DIR will prefer $DEST_DIR over HDD"
  exit 0
fi

if [[ -f "$DEST" && "${FORCE:-0}" != "1" ]]; then
  src_sz="$(stat -c %s "$SRC" 2>/dev/null || stat -f %z "$SRC")"
  dst_sz="$(stat -c %s "$DEST" 2>/dev/null || stat -f %z "$DEST")"
  if [[ "$src_sz" == "$dst_sz" ]]; then
    echo "OK: already present $DEST ($(du -h "$DEST" | awk '{print $1}'))"
    bash "$COMMON/ensure-posix-other-read.sh" "$DEST_DIR" "$DEST"
    exit 0
  fi
  echo "WARN: size mismatch hub vs hot; refreshing"
fi

echo "== promote GGUF $SRC -> $DEST =="
echo "  (this is ~17 GB; expect a few minutes on first copy)"
cp -f "$SRC" "$DEST.tmp"
mv -f "$DEST.tmp" "$DEST"
bash "$COMMON/ensure-posix-other-read.sh" "$DEST_DIR" "$DEST"
echo "OK: $DEST ($(du -h "$DEST" | awk '{print $1}'))"
echo "  Coordinator MODELS_DIR will prefer this path over HDD"
