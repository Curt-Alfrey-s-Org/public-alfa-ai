#!/usr/bin/env bash
# Idempotent iperf3 server bootstrap for ALFa AI Linux cluster members.
#
# Purpose
#   Make a Linux host ready to RECEIVE iperf3 throughput tests from other
#   cluster nodes. Installs iperf3 (or uses Docker), opens the firewall, and
#   launches a daemonized server on ${IPERF3_PORT:-5201} that survives reboots.
#
# Usage
#   bash scripts/iperf3-bootstrap.sh            # start / refresh server
#   bash scripts/iperf3-bootstrap.sh --stop     # stop + cleanup
#   bash scripts/iperf3-bootstrap.sh --status   # report current state
#   IPERF3_PORT=5202 bash scripts/iperf3-bootstrap.sh
#
# Strategy
#   1. If Docker is available (hub Scale 25.04+, Ubuntu with docker engine),
#      run `networkstatic/iperf3 -s -p <port>` as a --restart unless-stopped
#      container named 'iperf3-server'. Cleanest, survives reboot.
#   2. Otherwise install iperf3 via the detected package manager (apt / apk /
#      pacman / dnf) and run `iperf3 -s -D` as a backgrounded daemon; PID is
#      tracked in /run or /tmp, firewall opened.
#
# Exit codes
#   0  ok
#   1  target host policy failure (e.g. no package manager + no docker)
#   2  invalid argument
set -euo pipefail

PORT="${IPERF3_PORT:-5201}"
CONTAINER_NAME="${IPERF3_CONTAINER:-iperf3-server}"
PID_FILE="${IPERF3_PID_FILE:-/tmp/iperf3-server.pid}"
LOG_FILE="${IPERF3_LOG_FILE:-/tmp/iperf3-server.log}"
TAG='[iperf3-bootstrap]'

log()  { printf '%s %s\n' "$TAG" "$*"; }
warn() { printf '%s WARN: %s\n' "$TAG" "$*" >&2; }
die()  { printf '%s ERROR: %s\n' "$TAG" "$*" >&2; exit "${2:-1}"; }

MODE=start
case "${1:-}" in
  ''|start)   MODE=start ;;
  --stop)     MODE=stop ;;
  --status)   MODE=status ;;
  -h|--help)  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)          die "Unknown argument: $1 (use --help)" 2 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

docker_ready() {
  have docker || return 1
  docker info >/dev/null 2>&1
}

detect_pkg() {
  if   have apt-get; then echo apt
  elif have dnf;     then echo dnf
  elif have apk;     then echo apk
  elif have pacman;  then echo pacman
  else                    echo ''
  fi
}

install_iperf3_native() {
  local pkg
  pkg=$(detect_pkg)
  case "$pkg" in
    apt)    log "Installing iperf3 via apt-get..."; sudo apt-get update -qq && sudo apt-get install -y iperf3 ;;
    dnf)    log "Installing iperf3 via dnf...";     sudo dnf install -y iperf3 ;;
    apk)    log "Installing iperf3 via apk...";     sudo apk add --no-cache iperf3 ;;
    pacman) log "Installing iperf3 via pacman...";  sudo pacman -S --noconfirm iperf3 ;;
    *)      die "No supported package manager (apt/dnf/apk/pacman) AND no Docker. Install iperf3 manually." ;;
  esac
}

open_firewall() {
  # UFW (Ubuntu / Debian)
  if have ufw && sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
    if ! sudo ufw status | grep -q "${PORT}/tcp"; then
      log "Opening UFW ${PORT}/tcp..."
      sudo ufw allow "${PORT}/tcp" >/dev/null
    fi
    return
  fi
  # firewalld (RHEL / Fedora / some hub)
  if have firewall-cmd && sudo firewall-cmd --state 2>/dev/null | grep -q running; then
    if ! sudo firewall-cmd --list-ports | grep -qw "${PORT}/tcp"; then
      log "Opening firewalld ${PORT}/tcp..."
      sudo firewall-cmd --add-port="${PORT}/tcp" --permanent >/dev/null
      sudo firewall-cmd --reload >/dev/null
    fi
    return
  fi
  # iptables direct (rare, keep minimal)
  if have iptables && ! sudo iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
    log "No ufw/firewalld active. Skipping raw iptables (host-local policy)."
  fi
  log "No active firewall stack detected; assuming open / cloud SG handles it."
}

status_report() {
  if docker_ready && docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    log "Docker container '$CONTAINER_NAME' running:"
    docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    return
  fi
  if [[ -s "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    log "Native iperf3 daemon running (PID $(cat "$PID_FILE"))"
    return
  fi
  if pgrep -f "iperf3 -s -p ${PORT}" >/dev/null 2>&1; then
    log "Native iperf3 -s running (PID(s): $(pgrep -f "iperf3 -s -p ${PORT}" | tr '\n' ' '))"
    return
  fi
  log "No iperf3 server running on port ${PORT}."
}

stop_all() {
  local stopped=0
  if docker_ready && docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null && log "Removed container $CONTAINER_NAME." && stopped=1
  fi
  if [[ -s "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" && log "Killed native iperf3 daemon (PID $pid)." && stopped=1
    fi
    rm -f "$PID_FILE"
  fi
  if pgrep -f "iperf3 -s -p ${PORT}" >/dev/null 2>&1; then
    pkill -f "iperf3 -s -p ${PORT}" || true
    stopped=1
    log "Killed stray iperf3 -s processes."
  fi
  [[ "$stopped" -eq 0 ]] && log "Nothing to stop."
}

start_docker() {
  log "Launching Docker iperf3-server container on port ${PORT}..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  # --network host: iperf3 sees the real LAN directly (no NAT).
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network host \
    networkstatic/iperf3 \
    -s -p "$PORT" >/dev/null
  sleep 1
  docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
}

start_native() {
  have iperf3 || install_iperf3_native
  # kill any stale server on this port first
  pkill -f "iperf3 -s -p ${PORT}" 2>/dev/null || true
  sleep 1
  log "Launching native iperf3 -s -p ${PORT} (nohup)..."
  : > "$LOG_FILE" || true
  nohup iperf3 -s -p "$PORT" >> "$LOG_FILE" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  echo "$pid" > "$PID_FILE"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    log "Native daemon up (PID $pid, log: $LOG_FILE)"
  else
    die "iperf3 failed to start (check $LOG_FILE)"
  fi
}

case "$MODE" in
  status) status_report; exit 0 ;;
  stop)   stop_all;      exit 0 ;;
esac

log "Bootstrapping iperf3 server (port ${PORT})..."
open_firewall

if docker_ready; then
  start_docker
else
  start_native
fi

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "${HOST_IP:-}" ]] && HOST_IP=$(hostname)
log "Ready. Test from another host:  iperf3 -c ${HOST_IP} -p ${PORT} -t 10 -P 4"
