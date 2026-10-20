#!/usr/bin/env bash
# Remove incomplete / truncated hub GGUF downloads so aria2 can re-fetch cleanly.
#
# Run on hub hub only. See docs/HTTP_DOWNLOADS.md.
#
# Default: delete incomplete Qwen3-Coder-480B Q4_K_M shards (curl HTTP/2 CANCEL left
# a ~37G lead vs ~47G expected) plus matching *.aria2 control files and aria2 staging
# leftovers under ARIA2_HOST_STAGING / models/downloads.
#
# Usage:
#   sudo bash scripts/cleanup-partial-gguf-hub.sh --dry-run
#   sudo bash scripts/cleanup-partial-gguf-hub.sh
#   sudo bash scripts/cleanup-partial-gguf-hub.sh --also-aria2-controls
#
# Environment:
#   HUB_ROOT   default /mnt/hub/alfa-ai
#   GGUF_DIR   default $HUB_ROOT/llama-cpp/models
#
set -euo pipefail

HUB_ROOT="${HUB_ROOT:-/mnt/hub/alfa-ai}"
GGUF_DIR="${GGUF_DIR:-$HUB_ROOT/llama-cpp/models}"
STAGING="${ARIA2_HOST_STAGING:-$HUB_ROOT/models/downloads}"
DRY_RUN=0
ALSO_ARIA2_CONTROLS=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --also-aria2-controls) ALSO_ARIA2_CONTROLS=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown arg: $1" >&2; usage 1 ;;
  esac
done

HOST_IPS="$(hostname -I 2>/dev/null || true)"
if [[ -n "$HOST_IPS" ]] && [[ "$HOST_IPS" != *"hub"* ]] && [[ "${ALLOW_NON_HUB_CLEANUP:-0}" != "1" ]]; then
  echo "ERROR: run on hub only (or ALLOW_NON_HUB_CLEANUP=1)." >&2
  exit 1
fi

rm_path() {
  local p="$1"
  if [[ ! -e "$p" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN would remove: $p ($(du -sh "$p" 2>/dev/null | awk '{print $1}' || echo '?'))"
    return 0
  fi
  echo "Removing: $p ($(du -sh "$p" 2>/dev/null | awk '{print $1}' || echo '?'))"
  rm -rf "$p"
}

echo "GGUF_DIR=$GGUF_DIR"
echo "STAGING=$STAGING"
echo "DRY_RUN=$DRY_RUN"

# Incomplete 480B flagship (6 shards under Q4_K_M/).
shopt -s nullglob
for f in \
  "$GGUF_DIR"/Q4_K_M/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-*-of-00006.gguf \
  "$GGUF_DIR"/Q4_K_M/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-*-of-00006.gguf.aria2 \
  "$GGUF_DIR"/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-*-of-00006.gguf \
  "$GGUF_DIR"/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-*-of-00006.gguf.aria2
do
  rm_path "$f"
done

# Staging leftovers from aria2 RPC / prior curl attempts.
for f in \
  "$STAGING"/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-*-of-00006.gguf \
  "$STAGING"/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-*-of-00006.gguf.aria2 \
  "$STAGING"/Q4_K_M/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-*-of-00006.gguf \
  "$STAGING"/Q4_K_M/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-*-of-00006.gguf.aria2
do
  rm_path "$f"
done

if [[ "$ALSO_ARIA2_CONTROLS" -eq 1 ]]; then
  # Orphan control files under the model store (any model mid-download).
  while IFS= read -r -d '' ctrl; do
    rm_path "$ctrl"
  done < <(find "$GGUF_DIR" "$STAGING" -type f -name '*.aria2' -print0 2>/dev/null || true)
fi

echo "Done. Free space:"
df -h "$HUB_ROOT" 2>/dev/null || df -h /mnt/HDDs 2>/dev/null || true
echo "Re-fetch 480B with aria2 (after git pull + aria2 stack up):"
echo "  source deploy/cluster-members/hub/aria2-env.sh"
echo "  sudo -E MODELS_DIR=$GGUF_DIR REPO=unsloth/Qwen3-Coder-480B-A35B-Instruct-GGUF \\"
echo "    MODEL_LEAD=Q4_K_M/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-00001-of-00006.gguf \\"
echo "    HF_INCLUDE='Q4_K_M/*.gguf' bash deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh"
