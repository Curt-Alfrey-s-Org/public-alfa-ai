#!/usr/bin/env bash
# Load alfa-llamacpp-rpc:cuda128-pascal for gpu-248 GTX 1070 (Pascal sm_61).
#
# Canonical tarball: alfa-llamacpp-rpc-cuda128-pascal-b8552.tar.gz
# Build on hub: scripts/build-llamacpp-rpc-cuda128-pascal-on-hub.sh
#
# Usage:
#   bash deploy/cluster-members/_common/load-llamacpp-rpc-pascal-from-hub.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/preflight-docker-engine.sh"

IMAGE='alfa-llamacpp-rpc:cuda128-pascal'
TARBALL='alfa-llamacpp-rpc-cuda128-pascal-b10355.tar.gz'

if docker image inspect "$IMAGE" >/dev/null 2>&1 && [[ "${FORCE_HUB_RPC_LOAD:-}" != "1" ]]; then
  actual_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  echo "  Using existing $IMAGE id=$actual_id (skip hub load; FORCE_HUB_RPC_LOAD=1 to reload)"
  exit 0
fi

# Reuse local-cache helper with pascal tarball name (promote hub NFS -> local SSD once).
export ALFA_RPC_IMAGE="$IMAGE"
export ALFA_RPC_TARBALL="$TARBALL"
export ALFA_RPC_IMAGE_CACHE="${ALFA_RPC_IMAGE_CACHE:-${HOME}/alfa-ai-cache/docker-images}"
mkdir -p "$ALFA_RPC_IMAGE_CACHE"
tb="$(bash "$SCRIPT_DIR/ensure-rpc-image-local-cache.sh")"
tb_via="$(dirname "$tb")"
echo "  tarball source: $tb_via"

if [[ "$tb_via" == /mnt/cluster* || "$tb_via" == /mnt/HDDs/* ]]; then
  echo "ERROR: $TARBALL must be promoted to local SSD first (${ALFA_RPC_IMAGE_CACHE})" >&2
  echo "  NFS hub is seed-only; warm docker load reads local disk (docs/HUB_ARTIFACTS.md)." >&2
  exit 1
fi

manifest=""
for hub_manifest in \
  "$tb_via/images.json" \
  /mnt/hub/alfa-ai/docker-images/images.json \
  /mnt/cluster/docker-images/images.json \
  /mnt/nvme/Alfa-AI/docker-images/images.json \
  /mnt/ssd/Alfa-AI/docker-images/images.json
do
  if [[ -f "$hub_manifest" ]]; then
    manifest="$hub_manifest"
    break
  fi
done

expected_id=""
if [[ -f "$manifest" ]]; then
  expected_id="$(python3 - "$manifest" "$IMAGE" "$TARBALL" <<'PY'
import json, sys
manifest, tag, tar = sys.argv[1:4]
with open(manifest, encoding="utf-8-sig") as f:
    entries = json.load(f)
for e in entries:
    if e.get("image") == tag and e.get("file") == tar:
        print(e.get("id", ""))
        break
PY
)"
fi

echo "== docker load: $tb =="
docker load -i "$tb"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  loaded_id="$(docker images --format '{{.ID}}' --no-trunc | head -1)"
  if [[ -n "$loaded_id" ]]; then
    docker tag "$loaded_id" "$IMAGE"
  fi
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: $IMAGE missing after docker load" >&2
  exit 1
fi

actual_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
echo "  loaded $IMAGE id=$actual_id"
if [[ -n "$expected_id" && "$expected_id" != "$actual_id" ]]; then
  echo "  WARN: manifest id=$expected_id differs from loaded id=$actual_id" >&2
fi
