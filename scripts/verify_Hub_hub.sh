#!/usr/bin/env bash
# Read-only checks: can this host reach the hub hub (NFS + optional SMB hint)?
# Run from any Linux cluster member (e.g. inference hub). See CLUSTER_SHARED_STORAGE.md §3.
set -euo pipefail

hub_IP="${hub_IP:-hub}"
LOCAL_MOUNT="${LOCAL_MOUNT:-/mnt/cluster}"

echo "=== hub hub reachability ($hub_IP) ==="
echo ""

echo "1) ICMP (non-authoritative — firewalls may block)"
if ping -c 1 -W 2 "$hub_IP" &>/dev/null; then
  echo "   OK  ping $hub_IP"
else
  echo "   FAIL ping $hub_IP — host down, wrong subnet, or ICMP blocked"
fi
echo ""

echo "2) RPC mountd export list (often EMPTY on hub Scale NFSv4-only — not fatal)"
if command -v showmount &>/dev/null; then
  if out=$(showmount -e "$hub_IP" 2>&1); then
    echo "$out" | sed 's/^/   /'
    # Paths are first column on lines starting with /
    exports=$(echo "$out" | awk '/^\// { print $1 }' | sort -u)
    if [[ -n "$exports" ]]; then
      if echo "$exports" | grep -qiE 'Alfa-AI|alfa-ai-cluster'; then
        echo "   OK  at least one export looks like the ALFa hub (Alfa-AI / alfa-ai-cluster)."
      else
        echo "   ** PROBLEM **  NFS is exporting other paths (e.g. media) but NOT the ALFa dataset."
        echo "      Clients need a **second** UNIX (NFS) share: path **/mnt/hub/alfa-ai**,"
        echo "      Maproot root, network your LAN. SMB for \\\\hub\\\\temp is separate."
        echo "      See docs/CLUSTER_SHARED_STORAGE.md §3 — until this exists, /mnt/cluster cannot mount the hub."
      fi
    fi
  else
    echo "   showmount failed: $out"
  fi
else
  echo "   (showmount not installed — install nfs-common)"
fi
echo ""

echo "3) /mnt/cluster"
if mountpoint -q "$LOCAL_MOUNT" 2>/dev/null; then
  echo "   OK  $LOCAL_MOUNT is a mountpoint"
  findmnt -T "$LOCAL_MOUNT" 2>/dev/null | sed 's/^/   /' || true
  echo ""
  echo "   Large-artifact spots (if hub tree is populated):"
  for d in \
    "$LOCAL_MOUNT/models/huggingface/hub" \
    "$LOCAL_MOUNT/wheels/cuda" \
    "$LOCAL_MOUNT/wheels/cpu" \
    "$LOCAL_MOUNT/docker/images"; do
    if [[ -d "$d" ]]; then
      du -sh "$d" 2>/dev/null | sed 's/^/   /' || true
    else
      echo "   (missing) $d"
    fi
  done
else
  echo "   NOT MOUNTED — run: sudo bash scripts/mount_nfs_models.sh"
fi
echo ""

echo "4) Registry mirror (Docker pull-through on hub)"
if curl -fsS --max-time 3 "http://${hub_IP}:5000/v2/" &>/dev/null; then
  echo "   OK  http://${hub_IP}:5000/v2/"
else
  echo "   FAIL or blocked  http://${hub_IP}:5000/v2/  (mirror down or no route)"
fi
echo ""
echo "Done."
