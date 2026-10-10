#!/usr/bin/env bash
set -euo pipefail

# Build Docker images on apps, then save them as compressed tarballs to the NFS cluster share.
# Members load these with import_docker_images.sh instead of building from source.
#
# Usage (run on apps):
#   ./scripts/export_docker_images.sh                    # build + export
#   ./scripts/export_docker_images.sh --no-build         # export existing images only
#   ./scripts/export_docker_images.sh --no-cache         # build from scratch + export
#
# Requires: NFS share mounted at /mnt/cluster (run mount_nfs_models.sh first).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_DIR="$ROOT_DIR/deploy"

EXPORT_DIR="${CLUSTER_IMAGES_DIR:-/mnt/cluster/docker-images}"
MANIFEST="$EXPORT_DIR/images.json"

NO_BUILD=0
NO_CACHE=""
for arg in "$@"; do
  case "$arg" in
    --no-build) NO_BUILD=1 ;;
    --no-cache) NO_CACHE="--no-cache" ;;
    -h|--help)  sed -n '1,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)          echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$EXPORT_DIR" ]]; then
  echo "ERROR: Export directory not found: $EXPORT_DIR"
  echo "Mount the NFS share first: bash scripts/mount_nfs_models.sh"
  exit 1
fi

# Images to export: name as built by compose, tarball filename
IMAGES=(
  "alfa-ai-app:local                   alfa-ai-app.tar.gz"
)

# ── Build ────────────────────────────────────────────────────────────────────

if [[ "$NO_BUILD" -eq 0 ]]; then
  echo "=== Building main stack images ==="
  if [[ -f "$SCRIPT_DIR/docker_build_hash.sh" ]]; then
    export BUILD_HASH="$("$SCRIPT_DIR/docker_build_hash.sh")"
    echo "BUILD_HASH=$BUILD_HASH"
  fi
  (cd "$DEPLOY_DIR" && DOCKER_BUILDKIT=1 docker compose build $NO_CACHE)
fi

# ── Export ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Exporting images to $EXPORT_DIR ==="
echo ""

MANIFEST_ENTRIES=()

export_image() {
  local image_tag="$1" tarball="$2"
  local dest="$EXPORT_DIR/$tarball"

  image_tag="$(echo "$image_tag" | xargs)"
  tarball="$(echo "$tarball" | xargs)"

  if ! docker image inspect "$image_tag" &>/dev/null; then
    echo "  SKIP $image_tag (not found locally)"
    return
  fi

  local image_id
  image_id="$(docker image inspect "$image_tag" --format '{{.Id}}')"

  echo "  Saving $image_tag -> $tarball ..."
  docker save "$image_tag" | gzip > "$dest"

  local size
  size="$(du -h "$dest" | cut -f1)"
  echo "  Done ($size)"

  MANIFEST_ENTRIES+=("{\"image\":\"$image_tag\",\"file\":\"$tarball\",\"id\":\"$image_id\",\"exported\":\"$(date -Iseconds)\",\"size\":\"$size\"}")
}

for entry in "${IMAGES[@]}"; do
  read -r img tar <<< "$entry"
  export_image "$img" "$tar"
done

# ── Manifest ─────────────────────────────────────────────────────────────────

if [[ ${#MANIFEST_ENTRIES[@]} -eq 0 ]]; then
  echo "[]" > "$MANIFEST"
else
  printf '[%s]\n' "$(printf '%s,' "${MANIFEST_ENTRIES[@]}" | sed 's/,$//')" > "$MANIFEST"
  python3 -c "import json; json.load(open('$MANIFEST'))" 2>/dev/null || \
    echo "WARN: manifest JSON may be malformed; verify $MANIFEST"
fi

echo ""
echo "=== Export Complete ==="
echo "Manifest: $MANIFEST"
echo "Images:   $(ls -1 "$EXPORT_DIR"/*.tar.gz 2>/dev/null | wc -l) tarballs in $EXPORT_DIR"
echo ""
echo "Members load with: bash scripts/import_docker_images.sh"
