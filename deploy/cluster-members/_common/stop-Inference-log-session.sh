#!/usr/bin/env bash
# Stop background recorder and SCP session logs to orchestrator.
#
# Usage:
#   inference_LOG_SESSION_ID=20260702-120000 HOST_LABEL=105 bash .../stop-inference-log-session.sh
set -euo pipefail

_rp27_self="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_rp27_self%/*}"
[[ "$SCRIPT_DIR" == "$_rp27_self" || -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
# shellcheck source=inference-log-helpers.sh
source "$SCRIPT_DIR/inference-log-helpers.sh"

export inference_LOG_SESSION_ID="${inference_LOG_SESSION_ID:-$(inference_session_id)}"
HOST_LABEL="$(inference_resolve_host_label)"
SESSION_DIR="$(inference_session_dir)"
PID_FILE="$SESSION_DIR/recorder-${HOST_LABEL}.pid"
MODE_FILE="$SESSION_DIR/recorder-${HOST_LABEL}.mode"
UNIT_NAME="$(inference_recorder_unit_name)"

inference_stop_pid() {
  local pid="$1"
  local sig="$2"
  kill "-$sig" "$pid" 2>/dev/null && return 0
  sudo -n kill "-$sig" "$pid" 2>/dev/null
}

inference_rm_pid_file() {
  local file="$1"
  rm -f "$file" 2>/dev/null && return 0
  sudo -n rm -f "$file" 2>/dev/null
}

recorder_mode="$(cat "$MODE_FILE" 2>/dev/null || echo "")"

if [[ "$recorder_mode" == "systemd-run" ]] || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null); then
  echo "inference-record: stopping unit=$UNIT_NAME host=$HOST_LABEL"
  systemctl stop "$UNIT_NAME" 2>/dev/null || sudo -n systemctl stop "$UNIT_NAME" 2>/dev/null || true
elif [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE")"
  if kill -0 "$pid" 2>/dev/null || sudo -n kill -0 "$pid" 2>/dev/null; then
    echo "inference-record: stopping pid=$pid host=$HOST_LABEL"
    inference_stop_pid "$pid" TERM || true
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || sudo -n kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    inference_stop_pid "$pid" KILL || true
  fi
  inference_rm_pid_file "$PID_FILE" || true
else
  echo "inference-record: no pid file or unit for $HOST_LABEL (recorder may have already exited)"
fi

if [[ "${SCP_TO_93:-0}" == "1" ]]; then
  inference_scp_to_93 || true
fi
echo "inference-record: stop complete host=$HOST_LABEL session=$inference_LOG_SESSION_ID"