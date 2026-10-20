#!/usr/bin/env bash
# Build alfa-llamacpp-rpc:cuda128-pascal (sm_61+75+80+86+120) ON hub ONLY.
# For gpu-248 GTX 1070 (Pascal). Main cuda128 tarball unchanged for other hosts.
#
# Usage (on hub):
#   cd /mnt/hub/alfa-ai/repo/alfa-ai
#   sudo bash scripts/pack-llamacpp-vendor-tarball-on-hub.sh b8552
#   sudo bash scripts/build-llamacpp-rpc-cuda128-pascal-on-hub.sh
#
# Workers (secondary):
#   bash deploy/cluster-members/_common/load-llamacpp-rpc-pascal-from-hub.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HUB_ROOT="${HUB_ROOT:-/mnt/hub/alfa-ai}"
IMAGE_DIR="${HUB_ROOT}/docker-images"
LLAMACPP_TAG="${LLAMACPP_TAG:-b10355}"
TARBALL="alfa-llamacpp-rpc-cuda128-pascal-${LLAMACPP_TAG}.tar.gz"
IMAGE_TAG="alfa-llamacpp-rpc:cuda128-pascal"
TS="$(date +%Y%m%d-%H%M%S)"
H="$(hostname -s)"
LOG="/tmp/build-llamacpp-cuda128-pascal-hub-${H}-${TS}.log"

echo "LOG=${LOG}"
cd "$ROOT_DIR"

COMMON="$ROOT_DIR/deploy/cluster-members/_common"
bash "$COMMON/preflight-docker-engine.sh" 2>&1 | tee -a "$LOG"

docker_wrap() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif sudo docker info >/dev/null 2>&1; then
    sudo docker "$@"
  else
    echo "ERROR: Docker daemon not reachable on hub" >&2
    exit 1
  fi
}

docker_wrap info >/dev/null

bash "$ROOT_DIR/deploy/cluster-members/hub/pack-llamacpp-vendor-to-hub.sh" "$LLAMACPP_TAG" 2>&1 | tee -a "$LOG"

VENDOR_SRC="$HUB_ROOT/smb-scratch/cluster_members/_common/source-tarballs/llama.cpp.tar.gz"
VENDOR_DST="$ROOT_DIR/deploy/llamacpp-rpc/vendor/llama.cpp.tar.gz"
if [[ ! -f "$VENDOR_SRC" ]]; then
  echo "ERROR: missing vendor tarball after pack: $VENDOR_SRC" >&2
  exit 1
fi
mkdir -p "$(dirname "$VENDOR_DST")"
cp -f "$VENDOR_SRC" "$VENDOR_DST"

BUILD_JOBS="${ALFA_HUB_BUILD_JOBS:-6}"
CLEANUP_SH="$COMMON/docker-host-cleanup.sh"
run_abort_cleanup() {
  if [[ ! -f "$CLEANUP_SH" ]]; then
    return 0
  fi
  echo "== abort cleanup (builder cache + hub .tmp) ==" | tee -a "$LOG" || true
  ALFA_DOCKER_CLEANUP_MODE=abort ALFA_HUB_ROOT="$HUB_ROOT" bash "$CLEANUP_SH" 2>&1 | tee -a "$LOG" || true
}
trap 'run_abort_cleanup; exit 130' INT
trap 'run_abort_cleanup; exit 143' TERM

echo "== docker build $IMAGE_TAG ($LLAMACPP_TAG, sm_61+75+80+86+120) BUILD_JOBS=${BUILD_JOBS} ==" | tee -a "$LOG"
docker_wrap build -f deploy/llamacpp-rpc/Dockerfile.rpc-cuda128-pascal \
  --build-arg LLAMACPP_TAG="$LLAMACPP_TAG" \
  --build-arg BUILD_JOBS="$BUILD_JOBS" \
  -t "$IMAGE_TAG" \
  deploy/llamacpp-rpc 2>&1 | tee -a "$LOG"
build_exit="${PIPESTATUS[0]}"
echo "BUILD_EXIT=${build_exit}" | tee -a "$LOG"
if [[ "$build_exit" -ne 0 ]]; then
  run_abort_cleanup
  exit "$build_exit"
fi

DEST="${IMAGE_DIR}/${TARBALL}"
TMP="${IMAGE_DIR}/.${TARBALL}.tmp"
MANIFEST="${IMAGE_DIR}/images.json"

mkdir -p "$IMAGE_DIR"
echo "== docker save -> $DEST ==" | tee -a "$LOG"
if ! docker_wrap save "$IMAGE_TAG" | gzip > "$TMP"; then
  rm -f "$TMP"
  run_abort_cleanup
  exit 1
fi
mv "$TMP" "$DEST"
chmod a+rX "$IMAGE_DIR"
chown operator:operator "$DEST"
chmod a+r "$DEST"
setfacl -m u:Corey:r -m u:Colin:r -m u:Cody:r -m u:operator:r -m u:operator:r "$DEST"
trap - INT TERM

IMG_ID="$(docker_wrap image inspect "$IMAGE_TAG" --format '{{.Id}}')"
SIZE="$(du -h "$DEST" | cut -f1)"
echo "published $TARBALL ($SIZE) id=$IMG_ID" | tee -a "$LOG"

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
import subprocess, tempfile, os as _os
cid = subprocess.check_output(["docker", "create", tag], text=True).strip()
tmp = None
try:
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmp = tf.name
    subprocess.check_call(["docker", "cp", f"{cid}:/usr/local/bin/ggml-rpc-server", tmp])
    import hashlib
    h = hashlib.sha256()
    with open(tmp, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    entries[-1]["rpc_server_sha256"] = h.hexdigest()
finally:
    subprocess.call(["docker", "rm", cid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if tmp and _os.path.exists(tmp):
        _os.remove(tmp)
with open(manifest, "w") as f:
    json.dump(entries, f, indent=2)
print(f"updated manifest: {manifest}")
PY
chmod a+r "$MANIFEST"

echo ""
echo "build-llamacpp-rpc-cuda128-pascal-on-hub OK"
echo "  tarball: $DEST"
echo "  image:   $IMAGE_TAG id=$IMG_ID"
echo "Workers: load-llamacpp-rpc-pascal-from-hub.sh on gpu-248 (promotes to ~/alfa-ai-cache on local SSD)"
if [[ -f "$ROOT_DIR/deploy/cluster-members/hub/promote-rpc-image-to-nvme.sh" ]]; then
  echo "== promote pascal tarball to hub SSD/NVMe hot tier =="
  ALFA_RPC_TARBALL="$TARBALL" bash "$ROOT_DIR/deploy/cluster-members/hub/promote-rpc-image-to-nvme.sh" 2>&1 | tee -a "$LOG" || true
fi
