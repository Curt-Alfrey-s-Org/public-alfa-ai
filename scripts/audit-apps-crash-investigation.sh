#!/usr/bin/env bash
# Crash / OOM investigation for apps (web-sites / VM105 guest).
# Run ON apps: bash scripts/audit-105-crash-investigation.sh
# Writes: logs/crash-audit/audit-105-<host>-<timestamp>.log
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_ROOT}/logs/crash-audit"
TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
OUT="${OUT_DIR}/audit-105-${HOST}-${TS}.log"
mkdir -p "$OUT_DIR"

section() { echo ""; echo "======== $* ========"; }

{
  section "META"
  echo "date: $(date -Iseconds)"
  echo "host: $(hostname -f 2>/dev/null || hostname)"
  echo "uptime: $(uptime 2>/dev/null || true)"
  echo "kernel: $(uname -r 2>/dev/null || true)"

  section "MEMORY / LOAD"
  free -h 2>/dev/null || true
  echo "---"
  uptime 2>/dev/null || true

  section "DISK"
  df -h 2>/dev/null || true
  echo "--- docker system df ---"
  docker system df 2>/dev/null || sudo docker system df 2>/dev/null || true

  section "KERNEL OOM / KILL (dmesg)"
  if dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill|Killed process' | tail -40; then
    :
  elif sudo dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill|Killed process' | tail -40; then
    :
  else
    echo "(no OOM lines in dmesg or need sudo)"
  fi

  section "JOURNAL ERRORS (current boot, last 80)"
  journalctl -b -p err..alert --no-pager 2>/dev/null | tail -80 || \
    sudo journalctl -b -p err..alert --no-pager 2>/dev/null | tail -80 || true

  section "JOURNAL OOM/DOCKER/PETALS (7 days, last 60)"
  journalctl --since "7 days ago" --no-pager 2>/dev/null | \
    grep -iE 'oom|out of memory|killed process|docker.*die|postgres|redis|petals|segfault|panic|watchdog' | tail -60 || \
  sudo journalctl --since "7 days ago" --no-pager 2>/dev/null | \
    grep -iE 'oom|out of memory|killed process|docker.*die|postgres|redis|petals|segfault|panic|watchdog' | tail -60 || true

  section "PREVIOUS BOOT ERRORS (if rebooted)"
  journalctl -b -1 -p err..alert --no-pager 2>/dev/null | tail -40 || \
    sudo journalctl -b -1 -p err..alert --no-pager 2>/dev/null | tail -40 || \
    echo "(no previous boot or permission denied)"

  section "DOCKER EXITED / RESTARTING"
  docker ps -a --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | \
    grep -iE 'exit|restart|unhealthy|dead' | head -30 || \
  sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | \
    grep -iE 'exit|restart|unhealthy|dead' | head -30 || true

  section "DOCKER MEMORY (top consumers)"
  docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' 2>/dev/null | head -25 || \
  sudo docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' 2>/dev/null | head -25 || true

  section "ALFA / PETALS CONTAINER LOG TAIL (errors)"
  CONTAINER_RE='^(alfa-|alfa-ai-|petals-|worker-|monitoring-|rankings-|atems-|alfa-postgres|alfa-redis)'
  mapfile -t NAMES < <(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "$CONTAINER_RE" || \
    sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "$CONTAINER_RE" || true)
  for c in "${NAMES[@]}"; do
    echo "--- $c (error lines) ---"
    docker logs "$c" 2>&1 | grep -iE 'error|fatal|oom|killed|exception|panic|segfault' | tail -15 || \
      sudo docker logs "$c" 2>&1 | grep -iE 'error|fatal|oom|killed|exception|panic|segfault' | tail -15 || true
  done

  section "RECENT ALFA LOG FILES"
  ls -lt "${REPO_ROOT}/logs/cluster-docker/" 2>/dev/null | head -8 || true
  ls -lt "${REPO_ROOT}/deploy/cluster-members/apps/logs/" 2>/dev/null | head -8 || true

  section "LIBVIRT (nested VMs on apps)"
  systemctl is-active libvirtd 2>/dev/null || true
  journalctl -u libvirtd --since "7 days ago" --no-pager 2>/dev/null | tail -20 || \
    sudo journalctl -u libvirtd --since "7 days ago" --no-pager 2>/dev/null | tail -20 || true

  section "DONE"
  echo "Report: $OUT"
} | tee "$OUT"

echo ""
echo "Saved: $OUT"
echo "Copy to analyze elsewhere: scp operator@apps:$OUT ."
