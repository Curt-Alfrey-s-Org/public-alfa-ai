#!/usr/bin/env bash
# Read-only inventory: HDD hub (via NFS/SMB mount) + hints for hub-local checks.
#
# From a Linux member with the hub mounted (e.g. inference):
#   HUB_ROOT=/mnt/cluster bash scripts/audit-alfa-hub-inventory.sh
#
# For ZFS SSD/NVMe pools and /mnt/ssd paths, SSH to hub (hub) as root/operator
# and run the "On hub only" block printed at the end.
set -euo pipefail

HUB_ROOT="${HUB_ROOT:-/mnt/cluster}"
hub_IP="${hub_IP:-hub}"

echo "=== ALFa hub inventory (HUB_ROOT=$HUB_ROOT) ==="
echo ""

if [[ ! -d "$HUB_ROOT" ]]; then
  echo "ERROR: $HUB_ROOT missing. Mount hub: sudo bash scripts/mount_nfs_models.sh" >&2
  exit 1
fi

echo "--- Wheels ---"
for v in cpu cuda cuda-blackwell; do
  d="$HUB_ROOT/wheels/$v"
  if [[ -d "$d" ]]; then
    du -sh "$d" 2>/dev/null | awk -v n="$v" '{print "  " n ": " $1}'
  else
    echo "  $v: MISSING dir $d"
  fi
done
echo ""

echo "--- llama.cpp vendor source tarball (optional offline build) ---"
ST="$HUB_ROOT/smb-scratch/cluster_members/_common/source-tarballs/llama.cpp.tar.gz"
if [[ -f "$ST" ]]; then
  ls -lh "$ST"
else
  echo "  MISSING $ST  (pack on hub: sudo bash scripts/pack-llamacpp-vendor-tarball-on-hub.sh)"
fi
echo ""

echo "--- Docker image tarballs (canonical: \$HUB_ROOT/docker-images/) ---"
DI="$HUB_ROOT/docker-images"
if [[ -d "$DI" ]]; then
  du -sh "$DI" 2>/dev/null
  ls -lah "$DI" 2>/dev/null
else
  echo "  MISSING $DI"
fi
echo ""
echo "  (legacy) docker/images (should align with CLUSTER_SHARED_STORAGE or symlink):"
if [[ -d "$HUB_ROOT/docker/images" ]]; then
  du -sh "$HUB_ROOT/docker/images" 2>/dev/null
  ls -lah "$HUB_ROOT/docker/images" 2>/dev/null | head -20
fi
echo ""

echo "--- Models: HuggingFace hub ---"
HF="$HUB_ROOT/models/huggingface/hub"
if [[ -d "$HF" ]]; then
  du -sh "$HF"
  ls -1 "$HF" 2>/dev/null | grep '^models--' | head -15
else
  echo "  MISSING $HF"
fi
echo ""

echo "--- Models: Ollama cold (HDD) ---"
OC="$HUB_ROOT/models/ollama"
if [[ -d "$OC" ]]; then
  du -sh "$OC"
else
  echo "  MISSING $OC"
fi
echo ""

echo "--- llama.cpp GGUF ---"
GG="$HUB_ROOT/llama-cpp/models"
if [[ -d "$GG" ]]; then
  du -sh "$GG"
  find "$GG" -maxdepth 3 -type f -name '*.gguf' -printf '  %p\n' 2>/dev/null | head -25
  n="$(find "$GG" -type f -name '*.gguf' 2>/dev/null | wc -l)"
  echo "  (.gguf file count: $n)"
else
  echo "  MISSING $GG"
fi
echo ""

echo "--- Registry mirror (HTTP) ---"
if curl -fsS --max-time 3 "http://${hub_IP}:5000/v2/" &>/dev/null; then
  echo "  OK  http://${hub_IP}:5000/v2/"
else
  echo "  FAIL  http://${hub_IP}:5000/v2/  (mirror down or blocked from this host)"
fi
echo ""

echo "--- Optional: hub_hub_models status (Ollama list, GGUF file check) ---"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/hub_hub_models.sh" ]]; then
  HUB_ROOT="$HUB_ROOT" bash "$SCRIPT_DIR/hub_hub_models.sh" status || true
else
  echo "  (hub_hub_models.sh not found next to this script)"
fi

echo ""
echo "=== On hub (hub) only — SSD / NVMe fast pool (not visible over typical NFS) ==="
echo "SSH to hub (e.g. operator with sudo). If \`zfs\` is \"command not found\", it is not"
echo "on a non-root PATH — use: sudo zfs list -o name,used,avail,mountpoint"
echo "  (or: /usr/sbin/zfs list ...)"
echo ""
echo "  df -h | grep -E 'HDDs|ssd|nvme|boot-pool'   # works without zfs in PATH"
echo "  ls -la /mnt/ssd /mnt/nvme 2>/dev/null || true"
echo "  du -sh /mnt/ssd/* 2>/dev/null || true"
echo "  du -sh /mnt/nvme 2>/dev/null || true   # omit * if /mnt/nvme missing (zsh: no matches)"
echo ""
echo "Typical Scale layout: HDDs pool -> /mnt/hub/alfa-ai (hub); ssd pool -> /mnt/ssd/ollama (hot);"
echo "no /mnt/nvme until you add an NVMe data pool (optional — see hub_111_NVME_POOL.md)."
echo ""
echo "=== Typical gaps to fix on hub (seed / publish; no worker internet for big blobs) ==="
echo "  - Registry:  cd /mnt/hub/alfa-ai/repo/alfa-ai && sudo docker compose -f deploy/cluster-members/hub/docker-compose.registry.yml up -d"
echo "  - Petals ml-base (Ampere): sudo bash scripts/build-worker-image-on-hub.sh cuda"
echo "  - llama.cpp RPC image: build Dockerfile.rpc-cuda128 on hub, then bash scripts/publish-built-image-to-hub.sh alfa-llamacpp-rpc:cuda128"
echo "  - Hot Ollama: rsync cold -> SSD (see CLUSTER_SHARED_STORAGE.md), e.g."
echo "      rsync -aHAX --info=progress2 /mnt/hub/alfa-ai/models/ollama/ /mnt/ssd/ollama/"
echo ""
echo "Done."
