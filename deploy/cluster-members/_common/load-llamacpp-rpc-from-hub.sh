#!/usr/bin/env bash
# Load alfa-llamacpp-rpc:cuda128 — permanent fast path.
#
# 1. If Docker already has the image, skip (FORCE_HUB_RPC_LOAD=1 to reload).
# 2. ensure-rpc-image-local-cache.sh promotes hub -> local/NVMe once.
# 3. docker load from that local path (not NFS) whenever possible.
#
# Canonical tarball: alfa-llamacpp-rpc-cuda128-b10355.tar.gz
# Build on hub: scripts/build-llamacpp-rpc-cuda128-on-hub.sh
# Docs: docs/HUB_ARTIFACTS.md (b10355 for qwen3next / Pool80)
#
# Usage:
#   bash deploy/cluster-members/_common/load-llamacpp-rpc-from-hub.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/preflight-docker-engine.sh"

IMAGE='alfa-llamacpp-rpc:cuda128'
TARBALL='alfa-llamacpp-rpc-cuda128-b10355.tar.gz'

if docker image inspect "$IMAGE" >/dev/null 2>&1 && [[ "${FORCE_HUB_RPC_LOAD:-}" != "1" ]]; then
  actual_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  echo "  Using existing $IMAGE id=$actual_id (skip hub load; FORCE_HUB_RPC_LOAD=1 to reload)"
  exit 0
fi

tb="$(bash "$SCRIPT_DIR/ensure-rpc-image-local-cache.sh")"
tb_via="$(dirname "$tb")"
echo "  tarball source: $tb_via"

case "$tb_via" in
  /mnt/cluster*|/mnt/HDDs/*)
    bash "$SCRIPT_DIR/preflight-nfs-hub.sh"
    ;;
esac

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

if [[ -n "$expected_id" && "$actual_id" != "$expected_id" ]]; then
  cid="$(docker create "$IMAGE")"
  docker cp "$cid:/usr/local/bin/ggml-rpc-server" /tmp/alfa-rpc-server-verify >/dev/null \
    || docker cp "$cid:/usr/local/bin/rpc-server" /tmp/alfa-rpc-server-verify >/dev/null
  docker rm "$cid" >/dev/null
  rpc_sha="$(sha256sum /tmp/alfa-rpc-server-verify | awk '{print $1}')"
  rm -f /tmp/alfa-rpc-server-verify
  expected_rpc=""
  if [[ -f "$manifest" ]]; then
    expected_rpc="$(python3 - "$manifest" "$IMAGE" "$TARBALL" <<'PY'
import json, sys
manifest, tag, tar = sys.argv[1:4]
with open(manifest, encoding="utf-8-sig") as f:
    for e in json.load(f):
        if e.get("image") == tag and e.get("file") == tar and e.get("rpc_server_sha256"):
            print(e["rpc_server_sha256"])
            break
PY
)"
  fi
  if [[ -n "$expected_rpc" && "$rpc_sha" == "$expected_rpc" ]]; then
    echo "  WARN: image ID differs from images.json; rpc-server SHA256 matches hub manifest" >&2
  else
    echo "ERROR: image ID mismatch after hub load" >&2
    echo "  expected (images.json): $expected_id" >&2
    echo "  actual:                 $actual_id" >&2
    echo "  rpc-server sha256:      $rpc_sha" >&2
    echo "  Rebuild on hub and republish $TARBALL" >&2
    exit 1
  fi
elif [[ -n "$expected_id" ]]; then
  echo "  OK: matches hub images.json"
fi
