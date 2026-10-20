#!/usr/bin/env bash
# Proxmox host crash investigation for VM105 (apps guest at apps).
# Run ON Proxmox hypervisor as root: bash audit-proxmox-vm105.sh [VMID]
# Default VMID=105 if not passed.
set -uo pipefail

VMID="${1:-105}"
OUT="/tmp/audit-proxmox-vm${VMID}-$(date +%Y%m%d-%H%M%S).log"

{
  echo "======== META ========"
  echo "date: $(date -Iseconds)"
  echo "host: $(hostname -f 2>/dev/null || hostname)"
  echo "uptime: $(uptime 2>/dev/null || true)"
  echo "vmid: $VMID"

  echo ""
  echo "======== VM LIST / STATUS ========"
  qm list 2>/dev/null || true
  echo "--- qm status $VMID ---"
  qm status "$VMID" 2>/dev/null || echo "qm status failed (wrong VMID or not QEMU VM?)"

  echo ""
  echo "======== VM CONFIG (memory, cpu, balloon) ========"
  qm config "$VMID" 2>/dev/null | grep -iE '^(memory|cores|balloon|onboot|startup|hook|hostpci|machine|bios)' || true

  echo ""
  echo "======== HOST MEMORY ========"
  free -h 2>/dev/null || true

  echo ""
  echo "======== HOST OOM / KILL (dmesg) ========"
  dmesg -T 2>/dev/null | grep -iE "out of memory|oom-kill|Killed process|kvm.*$VMID|qemu" | tail -40 || true

  echo ""
  echo "======== JOURNAL: QEMU / VM $VMID (7 days) ========"
  journalctl --since "7 days ago" --no-pager 2>/dev/null | \
    grep -iE "qemu.*${VMID}|VM ${VMID}|vmid.*${VMID}|oom|out of memory|watchdog|task.*${VMID}" | tail -50 || true

  echo ""
  echo "======== PREVIOUS BOOT ERRORS (host) ========"
  journalctl -b -1 -p err..alert --no-pager 2>/dev/null | tail -30 || echo "(no previous boot)"

  echo ""
  echo "======== RECENT PVE TASKS ========"
  ls -lt /var/log/pve/tasks/ 2>/dev/null | head -15 || true
  # Last few task files mentioning the VM
  grep -l "$VMID" /var/log/pve/tasks/* 2>/dev/null | head -5 | while read -r f; do
    echo "--- task file: $f ---"
    tail -20 "$f" 2>/dev/null || true
  done

  echo ""
  echo "======== ZFS / STORAGE (if applicable) ========"
  zpool list 2>/dev/null || true
  df -h /var/lib/vz 2>/dev/null || df -h / 2>/dev/null || true

  echo ""
  echo "======== DONE ========"
} | tee "$OUT"

echo ""
echo "Saved: $OUT"
