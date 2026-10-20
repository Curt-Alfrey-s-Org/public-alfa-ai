#!/usr/bin/env bash
# Publish a locally-built Docker image up to the hub hub so workers
# docker-load it instead of re-downloading/rebuilding. Use on apps (Linux) or
# any Linux host that already has a binary-identical image.
#
# Policy: .cursor/rules/hub-hub-first.mdc, docs/HUB_ARTIFACTS.md
#
# Usage (on the hub or any Linux host with /mnt/cluster mounted):
#   ./scripts/publish-built-image-to-hub.sh alfa-llamacpp-rpc:cuda128
#   ./scripts/publish-built-image-to-hub.sh ghcr.io/home-assistant/home-assistant:2026.7.3 \
#       home-assistant-2026.7.3.tar.gz
#
# If <tarball> is omitted, it's derived from the tag:
#   alfa-llamacpp-rpc:cuda128 -> alfa-llamacpp-rpc-cuda128.tar.gz
set -euo pipefail

IMAGE_TAG="${1:-}"
TARBALL="${2:-}"
IMAGE_DIR="${IMAGE_DIR:-/mnt/cluster/docker-images}"
MANIFEST="${IMAGE_DIR}/images.json"

if [[ -z "$IMAGE_TAG" ]]; then
  echo "Usage: $0 <image:tag> [tarball.tar.gz]" >&2
  exit 2
fi

if [[ -z "$TARBALL" ]]; then
  TARBALL="$(echo "$IMAGE_TAG" | tr ':/' '-').tar.gz"
fi

if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "ERROR: image not found locally: $IMAGE_TAG" >&2
  echo "Build it first (and on the right host) before publishing." >&2
  exit 1
fi

if [[ ! -d "$IMAGE_DIR" ]]; then
  echo "ERROR: hub image dir not mounted: $IMAGE_DIR" >&2
  echo "Mount with: bash scripts/mount_nfs_models.sh" >&2
  exit 1
fi

if ! touch "${IMAGE_DIR}/.write-test-$$" 2>/dev/null; then
  echo "ERROR: hub image dir is not writable from this host: $IMAGE_DIR" >&2
  echo "Publish on hub hub (local path /mnt/hub/alfa-ai/docker-images/):" >&2
  echo "  sudo bash scripts/build-worker-image-on-hub.sh cuda-runtime" >&2
  exit 1
fi
rm -f "${IMAGE_DIR}/.write-test-$$"

DEST="${IMAGE_DIR}/${TARBALL}"
TMP="${IMAGE_DIR}/.${TARBALL}.tmp"

echo "==> docker save $IMAGE_TAG -> $DEST"
docker save "$IMAGE_TAG" | gzip > "$TMP"
mv "$TMP" "$DEST"

IMG_ID="$(docker image inspect "$IMAGE_TAG" --format '{{.Id}}')"
SIZE="$(du -h "$DEST" | cut -f1)"
echo "==> published $TARBALL ($SIZE) id=$IMG_ID"

python3 - "$MANIFEST" "$IMAGE_TAG" "$TARBALL" "$IMG_ID" "$SIZE" <<'PY'
import json, os, sys, datetime
manifest, tag, tar, img_id, size = sys.argv[1:]
entries = []
if os.path.exists(manifest):
    try:
        with open(manifest) as f:
            entries = json.load(f)
    except Exception:
        entries = []
entries = [e for e in entries if e.get("image") != tag]
entries.append({
    "image": tag, "file": tar, "id": img_id, "size": size,
    "exported": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "source_host": os.uname().nodename,
})
with open(manifest, "w") as f:
    json.dump(entries, f, indent=2)
print(f"updated manifest: {manifest}")
PY

echo ""
echo "Workers can now load:"
echo "  Linux:   docker load -i /mnt/cluster/docker-images/${TARBALL}"
echo "  Windows: docker load -i \\\\hub\\docker-images\\${TARBALL}"
