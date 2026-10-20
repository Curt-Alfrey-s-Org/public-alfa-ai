#!/usr/bin/env bash
# Pack llama.cpp sources into vendor/llama.cpp.tar.gz on the hub hub.
# Run on hub (or any host with HUB_ROOT writable and one-time GitHub access).
#
# Output (canonical):
#   $HUB_ROOT/smb-scratch/cluster_members/_common/source-tarballs/llama.cpp.tar.gz
# SMB: \\hub\temp\cluster_members\_common\source-tarballs\llama.cpp.tar.gz
#
# Usage:
#   sudo bash scripts/pack-llamacpp-vendor-tarball-on-hub.sh [LLAMACPP_TAG]
# Default tag matches Dockerfile.rpc-cuda128 (b8552+; includes qwen35 for Qwen3.6).
#
# Policy: docs/HUB_ARTIFACTS.md ? prefer creating this on hub; workers only copy from hub.
set -euo pipefail

TAG="${1:-b10355}"
HUB_ROOT="${HUB_ROOT:-/mnt/hub/alfa-ai}"
OUTDIR="$HUB_ROOT/smb-scratch/cluster_members/_common/source-tarballs"
OUT="$OUTDIR/llama.cpp.tar.gz"
VERSIONED="$OUTDIR/llama.cpp-${TAG}.tar.gz"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUTDIR"
echo "==> Cloning ggml-org/llama.cpp (branch/tag $TAG) into temp workspace"
git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$TMP/llama.cpp"

echo "==> Archiving to $OUT (and $VERSIONED)"
tar -czf "$OUT.tmp" -C "$TMP" llama.cpp
mv "$OUT.tmp" "$OUT"
cp -f "$OUT" "$VERSIONED"
ls -lh "$OUT" "$VERSIONED"
echo "Done. Windows members read: \\\\hub\\temp\\cluster_members\\_common\\source-tarballs\\llama.cpp.tar.gz"

