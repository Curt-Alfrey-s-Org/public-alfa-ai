#!/usr/bin/env bash
# Permanent fast path: ensure alfa-llamacpp-rpc tarball lives on local/NVMe disk.
#
# Called by load-llamacpp-rpc-from-hub.sh before docker load. If the image is
# already in Docker, load-*.sh exits early and this script is not needed.
#
# Policy (docs/HUB_ARTIFACTS.md):
#   1. Prefer existing local/NVMe tarball
#   2. Else copy once from hub (NFS/HDD) into the best writable local cache
#   3. Never download from the public internet
#
# Promote targets (first writable wins):
#   ALFA_RPC_IMAGE_CACHE
#   /mnt/nvme/Alfa-AI/docker-images   (hub fast tier)
#   /mnt/ssd/Alfa-AI/docker-images    (hub SSD tier)
#   $HOME/alfa-ai-cache/docker-images (pool-opt-in and other Linux workers)
#
# Usage:
#   bash deploy/cluster-members/_common/ensure-rpc-image-local-cache.sh
#   # prints absolute path to tarball on stdout (last line); status on stderr
set -euo pipefail

TARBALL="${ALFA_RPC_TARBALL:-alfa-llamacpp-rpc-cuda128-b10355.tar.gz}"

HUB_SOURCES=(
  /mnt/hub/alfa-ai/docker-images
  /mnt/cluster/docker-images
  /mnt/hub/alfa-ai/temp/cluster_members/_common/docker-images
  /mnt/hub/alfa-ai/smb-scratch/cluster_members/_common/docker-images
)

LOCAL_TARGETS=()
if [[ -n "${ALFA_RPC_IMAGE_CACHE:-}" ]]; then
  LOCAL_TARGETS+=("${ALFA_RPC_IMAGE_CACHE}")
fi
LOCAL_TARGETS+=(
  /mnt/nvme/Alfa-AI/docker-images
  /mnt/ssd/Alfa-AI/docker-images
  "${HOME}/alfa-ai-cache/docker-images"
)

is_local_fast() {
  local p="$1"
  case "$p" in
    /mnt/cluster*|/mnt/HDDs/*) return 1 ;;
    *) return 0 ;;
  esac
}

# Already have a fast local copy?
for root in "${LOCAL_TARGETS[@]}"; do
  if [[ -f "$root/$TARBALL" ]] && is_local_fast "$root"; then
    echo "  ensure-rpc-image-local-cache: hit $root/$TARBALL" >&2
    echo "$root/$TARBALL"
    exit 0
  fi
done

hub=""
for root in "${HUB_SOURCES[@]}"; do
  if [[ -f "$root/$TARBALL" ]]; then
    hub="$root/$TARBALL"
    break
  fi
done

if [[ -z "$hub" ]]; then
  echo "ERROR: $TARBALL not on hub (checked ${HUB_SOURCES[*]})" >&2
  exit 1
fi

dest_dir=""
for root in "${LOCAL_TARGETS[@]}"; do
  if [[ -d "$root" ]] || mkdir -p "$root" 2>/dev/null; then
    if [[ -w "$root" ]]; then
      dest_dir="$root"
      break
    fi
  fi
done

if [[ -z "$dest_dir" ]]; then
  echo "WARN: no writable local cache; will use hub path $hub" >&2
  echo "$hub"
  exit 0
fi

dest="$dest_dir/$TARBALL"
if [[ ! -f "$dest" ]]; then
  echo "  ensure-rpc-image-local-cache: promoting hub -> $dest (once)" >&2
  cp -f "$hub" "$dest.tmp"
  mv -f "$dest.tmp" "$dest"
  if [[ -f "$(dirname "$hub")/images.json" ]] && [[ ! -f "$dest_dir/images.json" ]]; then
    cp -f "$(dirname "$hub")/images.json" "$dest_dir/images.json" 2>/dev/null || true
  fi
else
  echo "  ensure-rpc-image-local-cache: already at $dest" >&2
fi

echo "$dest"
