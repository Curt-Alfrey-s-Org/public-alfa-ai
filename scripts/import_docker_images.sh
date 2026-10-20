#!/usr/bin/env bash
set -euo pipefail

# Load pre-built Docker images from the NFS cluster share (or a local path).
# Skips images that are already loaded with the same ID.
#
# Usage (run on any cluster member):
#   ./scripts/import_docker_images.sh
#   CLUSTER_IMAGES_DIR=/path/to/images ./scripts/import_docker_images.sh
#   ./scripts/import_docker_images.sh --force    # reload even if already present
#
# For Windows members without NFS, SCP the docker-images/ folder first:
#   scp -r operator@hub:/mnt/hub/alfa-ai-cluster/docker-images/ ./docker-images/
#   CLUSTER_IMAGES_DIR=./docker-images bash scripts/import_docker_images.sh

IMPORT_DIR="${CLUSTER_IMAGES_DIR:-/mnt/cluster/docker-images}"
MANIFEST="$IMPORT_DIR/images.json"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '1,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$IMPORT_DIR" ]]; then
  echo "ERROR: Import directory not found: $IMPORT_DIR"
  echo "Mount NFS first (bash scripts/mount_nfs_models.sh) or set CLUSTER_IMAGES_DIR."
  exit 1
fi

echo "=== Importing Docker images from $IMPORT_DIR ==="
echo ""

LOADED=0
SKIPPED=0

for tarball in "$IMPORT_DIR"/*.tar.gz; do
  [[ -f "$tarball" ]] || continue
  fname="$(basename "$tarball")"

  if [[ "$FORCE" -eq 0 ]] && [[ -f "$MANIFEST" ]]; then
    expected_id="$(python3 -c "
import json, sys
with open('$MANIFEST') as f:
    for e in json.load(f):
        if e.get('file') == '$fname':
            print(e.get('id', '')); sys.exit()
" 2>/dev/null || true)"

    if [[ -n "${expected_id:-}" ]]; then
      image_name="$(python3 -c "
import json
with open('$MANIFEST') as f:
    for e in json.load(f):
        if e.get('file') == '$fname':
            print(e.get('image', '')); break
" 2>/dev/null || true)"

      if [[ -n "$image_name" ]] && docker image inspect "$image_name" &>/dev/null; then
        local_id="$(docker image inspect "$image_name" --format '{{.Id}}' 2>/dev/null || true)"
        if [[ "$local_id" == "$expected_id" ]]; then
          echo "  SKIP $fname ($image_name already matches)"
          ((SKIPPED++))
          continue
        fi
      fi
    fi
  fi

  echo "  Loading $fname ..."
  if docker load < <(gunzip -c "$tarball") 2>&1 | tail -1; then
    ((LOADED++))
  else
    echo "  WARN: Failed to load $fname"
  fi
done

echo ""
echo "=== Import Complete ==="
echo "Loaded: $LOADED, Skipped: $SKIPPED"
