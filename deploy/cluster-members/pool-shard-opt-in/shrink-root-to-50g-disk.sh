#!/usr/bin/env bash
# Shrink VM100 root for 50 GB Proxmox disk (offline only).
#
# ext4 cannot shrink online. Run from emergency shell:
#   1. Reboot VM100, grub: edit kernel -> append init=/bin/bash
#   2. mount -o remount,rw /
#   3. bash /home/operator/shrink-root-to-50g-disk.sh
#   4. sync && reboot -f
#   5. On Proxmox: qm disk resize <vmid> <disk> 50G
set -euo pipefail

ROOT_DEV=/dev/ubuntu-vg/ubuntu-lv
PV_DEV=/dev/sda3
TARGET_LV=44G
PART_END=50GB

echo "== shrink root FS/LV/PV/partition for 50 GB Proxmox disk =="
mount | grep -q ' on / ' || { echo "ERROR: mount / first (mount -o remount,rw /)" >&2; exit 1; }

e2fsck -f "$ROOT_DEV"
resize2fs "$ROOT_DEV" "$TARGET_LV"
lvreduce -L "$TARGET_LV" -y "$ROOT_DEV"
pvresize --setphysicalvolumesize "$TARGET_LV" "$PV_DEV"
parted /dev/sda ---pretend-input-tty resizepart 3 "$PART_END" Yes
parted /dev/sda unit GB print
df -h /

echo ""
echo "Guest shrink complete. On Proxmox host (hypervisor):"
echo "  qm disk resize <vmid> <disk> 50G"
echo "Example (if VMID=100, virtio0): qm disk resize 100 virtio0 50G"