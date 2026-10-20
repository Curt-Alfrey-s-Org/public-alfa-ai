#!/usr/bin/env bash
# Install staggered weekly Docker cleanup cron (Linux / WSL).
# See docs/operations/DOCKER_HOST_CLEANUP.md
#
# Usage:
#   sudo bash deploy/cluster-members/_common/install-docker-cleanup-cron.sh
#   sudo bash deploy/cluster-members/_common/install-docker-cleanup-cron.sh --uninstall
#
# Env overrides: ALFA_CLEANUP_MINUTE HOUR DOW HOST, ALFA_AI_REPO
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-}"
if [[ -z "$REPO_DIR" ]]; then
  REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi
CLEANUP_SRC="$SCRIPT_DIR/docker-host-cleanup.sh"
CRON_FILE="/etc/cron.d/alfa-docker-cleanup"
LEGACY_CRON="/etc/cron.d/docker-cleanup"
DESC="alfa docker host cleanup"

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$CRON_FILE"
  echo "Removed $CRON_FILE"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root (sudo)" >&2
  exit 1
fi
if [[ ! -f "$CLEANUP_SRC" ]]; then
  echo "ERROR: missing $CLEANUP_SRC" >&2
  exit 1
fi

HOST_KEY="${ALFA_CLEANUP_HOST:-}"
if [[ -z "$HOST_KEY" ]]; then
  HN="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  HN_LC="$(echo "$HN" | tr '[:upper:]' '[:lower:]')"
  case "$HN_LC" in
    *148*|ai-148*|g-rev*) HOST_KEY=148 ;;
    *100*|alfa-ai*|vm100*) HOST_KEY=100 ;;
    *105*|apps*|ansible*|web-sites*|websites*) HOST_KEY=105 ;;
    *107*|monitor*) HOST_KEY=107 ;;
    *106*|uspbf*|rank*|probill*) HOST_KEY=106 ;;
    *102*|market*) HOST_KEY=102 ;;
    *103*|atems*) HOST_KEY=103 ;;
    *248*|gpu-248*) HOST_KEY=248 ;;
    *93*|operator*) HOST_KEY=93 ;;
    *219*|gaming-worker-a*) HOST_KEY=219 ;;
    *249*|gaming-worker-b*) HOST_KEY=249 ;;
    *59*|gaming-worker-c*) HOST_KEY=59 ;;
    *111*|hub*|hub*) HOST_KEY=111 ;;
    *) HOST_KEY=default ;;
  esac
fi
# Prefer numeric LAN octet when hostname is opaque (e.g. web-sites on apps).
if [[ "$HOST_KEY" == "default" ]]; then
  _ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  case "$_ip" in
    *inference) HOST_KEY=148 ;;
    *pool-opt-in) HOST_KEY=100 ;;
    *apps) HOST_KEY=105 ;;
    *monitor) HOST_KEY=107 ;;
    *probilliards) HOST_KEY=106 ;;
    *market) HOST_KEY=102 ;;
    *atems) HOST_KEY=103 ;;
    *secondary) HOST_KEY=248 ;;
    *orchestrator)  HOST_KEY=93 ;;
    *gaming-a) HOST_KEY=219 ;;
    *gaming-b) HOST_KEY=249 ;;
    *gaming-c)  HOST_KEY=59 ;;
    *hub) HOST_KEY=111 ;;
  esac
fi

# Sunday staggered (minute hour dow) — matches DOCKER_HOST_CLEANUP.md
MINUTE="${ALFA_CLEANUP_MINUTE:-}"
HOUR="${ALFA_CLEANUP_HOUR:-}"
DOW="${ALFA_CLEANUP_DOW:-0}"
case "$HOST_KEY" in
  111) MINUTE="${MINUTE:-0}";  HOUR="${HOUR:-3}" ;;
  148) MINUTE="${MINUTE:-15}"; HOUR="${HOUR:-3}" ;;
  100) MINUTE="${MINUTE:-30}"; HOUR="${HOUR:-3}" ;;
  105) MINUTE="${MINUTE:-45}"; HOUR="${HOUR:-3}" ;;
  107) MINUTE="${MINUTE:-0}";  HOUR="${HOUR:-4}" ;;
  106) MINUTE="${MINUTE:-15}"; HOUR="${HOUR:-4}" ;;
  102) MINUTE="${MINUTE:-30}"; HOUR="${HOUR:-4}" ;;
  103) MINUTE="${MINUTE:-45}"; HOUR="${HOUR:-4}" ;;
  93)  MINUTE="${MINUTE:-0}";  HOUR="${HOUR:-5}" ;;
  219) MINUTE="${MINUTE:-15}"; HOUR="${HOUR:-5}" ;;
  249) MINUTE="${MINUTE:-30}"; HOUR="${HOUR:-5}" ;;
  59)  MINUTE="${MINUTE:-45}"; HOUR="${HOUR:-5}" ;;
  248) MINUTE="${MINUTE:-0}";  HOUR="${HOUR:-6}" ;;
  *)   MINUTE="${MINUTE:-30}"; HOUR="${HOUR:-5}" ;;
esac

install -m 0755 "$CLEANUP_SRC" /usr/local/sbin/alfa-docker-host-cleanup.sh
# Prefer repo copy when present so git pull updates behavior without reinstall;
# cron still calls the installed copy for boot-time reliability.
RUN="/usr/local/sbin/alfa-docker-host-cleanup.sh"
if [[ -f "$REPO_DIR/deploy/cluster-members/_common/docker-host-cleanup.sh" ]]; then
  RUN="bash $REPO_DIR/deploy/cluster-members/_common/docker-host-cleanup.sh"
fi

LOG_DIR="/var/log"
mkdir -p "$LOG_DIR"
# cron.d requires a username field and a trailing newline.
cat > "$CRON_FILE" <<EOF
# ${HOST_KEY}: ${DESC} - docs/operations/DOCKER_HOST_CLEANUP.md
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${MINUTE} ${HOUR} * * ${DOW} root ALFA_DOCKER_CLEANUP_MODE=scheduled ${RUN} >> ${LOG_DIR}/alfa-docker-cleanup.log 2>&1
EOF
chmod 644 "$CRON_FILE"

# Retire legacy WSL one-liner cron (system prune only, no builder).
if [[ -f "$LEGACY_CRON" ]]; then
  rm -f "$LEGACY_CRON"
  echo "Removed legacy $LEGACY_CRON"
fi

echo "Installed $CRON_FILE"
echo "  host_key=$HOST_KEY schedule=${MINUTE} ${HOUR} * * ${DOW} (Sun)"
echo "  command=${RUN}"
echo "  log=${LOG_DIR}/alfa-docker-cleanup.log"
cat "$CRON_FILE"
