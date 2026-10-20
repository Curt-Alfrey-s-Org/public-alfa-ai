#!/usr/bin/env bash
set -euo pipefail

# Run ON each Linux cluster member to mount the hub NFS hub share.
# Idempotent: safe to run multiple times.
#
# hub Scale often returns an empty or unhelpful `showmount -e` while NFSv4.1
# mounts still work. This script probes candidate export paths when showmount
# does not list the canonical path.
#
# Override export path if you know it:
#   NFS_REMOTE=/mnt/hub/alfa-ai-cluster ./scripts/mount_nfs_models.sh
#
# Usage:
#   ./scripts/mount_nfs_models.sh
# hub NFS hub: prefer storage (NFS VIP on br1); hub fallback same L2.
#   hub_IP=orchestrator ./scripts/mount_nfs_models.sh
#
# Verify before/after: ./scripts/verify_hub_hub.sh
#
# For Windows members, use SMB (see docs/SOURCE_OF_TRUTH_AND_SYNC.md).

hub_IP="${hub_IP:-orchestrator}"
NFS_REMOTE="${NFS_REMOTE:-/mnt/hub/alfa-ai}"
LOCAL_MOUNT="${LOCAL_MOUNT:-/mnt/cluster}"

# Prefer NFS VIP (storage on br1); fall back to mgmt (hub) on same L2 when alias is down.
if ! timeout 2 ping -c1 -W1 "$hub_IP" &>/dev/null; then
  if [[ "$hub_IP" == "orchestrator" ]] && timeout 2 ping -c1 -W1 hub &>/dev/null; then
    echo "WARN: $hub_IP unreachable; trying NFS via hub"
    hub_IP="hub"
  fi
fi

# Candidates in order: explicit default first, then legacy symlink dataset name.
NFS_REMOTE_CANDIDATES=(
  "$NFS_REMOTE"
  "/mnt/hub/alfa-ai"
  "/mnt/hub/alfa-ai-cluster"
)

echo "=== Mounting hub cluster hub share ==="
echo "Server: $hub_IP"
echo "Preferred remote path: $NFS_REMOTE"
echo "Local mount:  $LOCAL_MOUNT"
echo ""

# 1. Install NFS client if missing
if ! command -v mount.nfs &>/dev/null; then
    echo "Installing nfs-common..."
    sudo apt-get update -qq && sudo apt-get install -y -qq nfs-common
fi

# 2. Create mount point
sudo mkdir -p "$LOCAL_MOUNT"

# 3. If already mounted and responsive, report and exit success.
# After bond/netplan changes autofs can show "mounted" while NFS is stale (ls hangs).
if mountpoint -q "$LOCAL_MOUNT"; then
    if timeout 5 test -d "$LOCAL_MOUNT/docker-images" 2>/dev/null; then
        echo "$LOCAL_MOUNT is already mounted:"
        findmnt "$LOCAL_MOUNT" || true
        exit 0
    fi
    echo "WARN: $LOCAL_MOUNT mountpoint exists but hub path is not responsive; remounting..."
    sudo umount -l "$LOCAL_MOUNT" 2>/dev/null || true
fi

# 4. showmount hint (non-fatal; bounded so stale storage does not hang the script)
SHOWMOUNT_OUT=""
if command -v showmount &>/dev/null; then
    SHOWMOUNT_OUT=$(timeout 5 showmount -e "$hub_IP" 2>&1 || true)
    if echo "$SHOWMOUNT_OUT" | grep -qF "$NFS_REMOTE"; then
        echo "showmount lists $NFS_REMOTE — good."
    elif echo "$SHOWMOUNT_OUT" | grep -q '/mnt/'; then
        echo "showmount export list (pick path in hub UI if mount fails):"
        echo "$SHOWMOUNT_OUT" | sed 's/^/  /'
    else
        echo "showmount empty or error (common on hub Scale). Will probe NFSv4.1 paths."
        echo "$SHOWMOUNT_OUT" | sed 's/^/  /'
    fi
else
    echo "showmount not found; probing paths."
fi
echo ""

# 5. Deduped candidate list
declare -A seen=()
CAND_LIST=()
for p in "${NFS_REMOTE_CANDIDATES[@]}"; do
    [[ -z "$p" ]] && continue
    if [[ -z "${seen[$p]:-}" ]]; then
        seen[$p]=1
        CAND_LIST+=("$p")
    fi
done

PROBE_DIR=""
cleanup_probe() {
    if [[ -n "${PROBE_DIR:-}" ]] && [[ -d "$PROBE_DIR" ]]; then
        sudo umount -l "$PROBE_DIR" 2>/dev/null || true
        rmdir "$PROBE_DIR" 2>/dev/null || true
    fi
}
trap cleanup_probe EXIT

PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nfs-hub-probe.XXXXXX")
chmod 711 "$PROBE_DIR"

CHOSEN=""
for path in "${CAND_LIST[@]}"; do
    echo "Probing (read-only): ${hub_IP}:${path}"
    if sudo mount -t nfs -o vers=4.1,ro,soft,timeo=30 "$hub_IP:$path" "$PROBE_DIR" 2>/tmp/nfs-probe.err; then
        CHOSEN="$path"
        echo "  OK — NFS accepted this export path."
        sudo umount "$PROBE_DIR" || sudo umount -l "$PROBE_DIR" || true
        break
    else
        echo "  No: $(head -1 /tmp/nfs-probe.err 2>/dev/null || echo 'mount failed')"
    fi
done

if [[ -z "$CHOSEN" ]]; then
    echo ""
    echo "ERROR: Could not NFS-mount any ALFa hub candidate path from $hub_IP."
    if [[ -n "${SHOWMOUNT_OUT:-}" ]] && echo "$SHOWMOUNT_OUT" | grep -q '/mnt/'; then
        if ! echo "$SHOWMOUNT_OUT" | grep -qiE 'Alfa-AI|alfa-ai-cluster'; then
            echo ""
            echo "Your server lists NFS exports, but none are the ALFa hub. Typical case:"
            echo "  only **/mnt/HDDs/media** (or similar) is shared — models/wheels/repo live on **/mnt/hub/alfa-ai**."
            echo "Add **another** NFS share on hub Scale:"
            echo "  **Shares → Unix Shares (NFS) → Add** → path **/mnt/hub/alfa-ai**"
            echo "  Maproot user **root**, authorized networks **orchestrator/24** (or your LAN), read/write."
            echo "Do not repoint **media**; add a **second** export for the Alfa-AI dataset."
        fi
    else
        echo "Fix on hub: **Shares → Unix Shares (NFS)** → path **/mnt/hub/alfa-ai**"
        echo "  Maproot root, network orchestrator/24 (or your LAN). See CLUSTER_SHARED_STORAGE.md §3."
    fi
    echo "Diagnostics: bash scripts/verify_hub_hub.sh"
    exit 1
fi

NFS_REMOTE="$CHOSEN"
echo ""
echo "Mounting read-write: ${hub_IP}:${NFS_REMOTE} -> $LOCAL_MOUNT"
sudo mount -t nfs -o vers=4.1,soft,timeo=600 "$hub_IP:$NFS_REMOTE" "$LOCAL_MOUNT"
echo "Mounted."
trap - EXIT
cleanup_probe

# 6. Persist in fstab (match CLUSTER_SHARED_STORAGE.md §3)
FSTAB_ENTRY="$hub_IP:$NFS_REMOTE $LOCAL_MOUNT nfs vers=4.1,_netdev,x-systemd.automount 0 0"
if ! grep -qF "$hub_IP:$NFS_REMOTE $LOCAL_MOUNT" /etc/fstab 2>/dev/null; then
    echo "Adding to /etc/fstab..."
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
else
    echo "fstab entry already present for this server+path+mountpoint."
fi

echo ""
echo "=== Mount Complete ==="
echo "Discovered / chosen export path: $NFS_REMOTE"
echo ""
echo "Available paths:"
echo "  Models (HF):      $LOCAL_MOUNT/models/huggingface"
echo "  Models (Ollama):  $LOCAL_MOUNT/models/ollama"
echo "  PyPI wheels:      $LOCAL_MOUNT/wheels/{cpu,cuda}"
echo "  Docker images:    $LOCAL_MOUNT/docker/images  (or legacy docker-images/)"
echo "  Installers:       $LOCAL_MOUNT/installers"
echo "  Git repo mirror:  $LOCAL_MOUNT/repo/alfa-ai"
echo ""
echo "Next: bash scripts/verify_hub_hub.sh"
