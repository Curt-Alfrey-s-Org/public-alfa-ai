#!/usr/bin/env bash
# Capture cluster-post-startup-status.sh to member logs/ and optionally SCP to inference hub.
#
# Usage:
#   HOST_PROFILE=hub-111 bash deploy/cluster-members/_common/run-post-startup-status-with-log.sh
#   HOST_PROFILE=operator-93 SCP_TO_BUILD_HOST=1 bash deploy/cluster-members/_common/run-post-startup-status-with-log.sh
#
# Env:
#   HOST_PROFILE   — required (see scripts/cluster-post-startup-status.sh)
#   MEMBER_LOG_DIR — override log directory (default: deploy/cluster-members/<profile-dir>/logs)
#   SSH_HOST       — default operator@orchestrator (cluster-hub.env)
#   REMOTE_DIR     — default …/alfa-ai/logs/cluster-status on hub
#   SCP_TO_BUILD_HOST — 1 to copy transcript to inference
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster-hub.env
source "$SCRIPT_DIR/cluster-hub.env" 2>/dev/null || true
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STATUS_SH="$REPO_ROOT/scripts/cluster-post-startup-status.sh"

HOST_PROFILE="${HOST_PROFILE:-}"
if [[ -z "$HOST_PROFILE" ]]; then
  echo "ERROR: set HOST_PROFILE (e.g. hub-111, apps-105, operator-93)" >&2
  exit 1
fi

profile_to_member_dir() {
  case "$1" in
    hub-111) echo hub-111 ;;
    apps-105) echo apps-105 ;;
    operator-93) echo operator-93 ;;
    gaming-worker-c-59) echo gaming-worker-c-59 ;;
    gaming-worker-a-219) echo gaming-worker-a-219 ;;
    gaming-worker-b-249) echo gaming-worker-b-249 ;;
    ai-148) echo ai-148 ;;
    *) echo "$1" ;;
  esac
}

MEMBER_DIR="${MEMBER_LOG_DIR:-$REPO_ROOT/deploy/cluster-members/$(profile_to_member_dir "$HOST_PROFILE")/logs}"
mkdir -p "$MEMBER_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
LOG_FILE="$MEMBER_DIR/post-startup-${HOST_PROFILE}-${HOST}-${TS}.log"

echo "Repo root:     $REPO_ROOT"
echo "HOST_PROFILE:  $HOST_PROFILE"
echo "Log file:      $LOG_FILE"
echo ""

cd "$REPO_ROOT"
set +e
export HOST_PROFILE
bash "$STATUS_SH" 2>&1 | tee "$LOG_FILE"
STATUS=${PIPESTATUS[0]}
set -e

echo ""
echo "Exit status: $STATUS"
echo "LOG FILE: $LOG_FILE"

if [[ "${SCP_TO_BUILD_HOST:-0}" == "1" ]]; then
  SSH_HOST="${SSH_HOST:-${HUB_SSH:-operator@orchestrator}}"
  REMOTE_DIR="${REMOTE_DIR:-${HUB_LOG_CLUSTER_STATUS:-/home/operator/alfa-ai/logs/cluster-status}}"
  echo ""
  echo "==> SCP_TO_BUILD_HOST=1 — copying to ${SSH_HOST}:${REMOTE_DIR}/"
  if ssh "$SSH_HOST" "mkdir -p '${REMOTE_DIR}'" && scp "$LOG_FILE" "${SSH_HOST}:${REMOTE_DIR}/"; then
    echo "==> Copied: ${REMOTE_DIR}/$(basename "$LOG_FILE")"
    echo "    Analysis on inference: grep -E 'FAIL|WARN|RESULT' '${REMOTE_DIR}/$(basename "$LOG_FILE")'"
  else
    echo "WARN: ssh/scp failed — copy manually:" >&2
    echo "  scp '$LOG_FILE' '${SSH_HOST}:${REMOTE_DIR}/'" >&2
    exit 1
  fi
fi

exit "$STATUS"
