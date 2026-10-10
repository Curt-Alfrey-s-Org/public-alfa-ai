#!/usr/bin/env bash
# Start a background inference log recorder on this host (for SSH-launched sessions).
#
# Usage:
#   inference_LOG_SESSION_ID=20260702-120000 HOST_LABEL=105 bash .../start-inference-log-session.sh
set -euo pipefail

_rp27_self="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_rp27_self%/*}"
[[ "$SCRIPT_DIR" == "$_rp27_self" || -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
# shellcheck source=inference-log-helpers.sh
source "$SCRIPT_DIR/inference-log-helpers.sh"

export ALFA_AI_REPO="${ALFA_AI_REPO:-$(inference_repo_root)}"
export inference_LOG_SESSION_ID="${inference_LOG_SESSION_ID:-$(inference_session_id)}"
export HOST_LABEL="$(inference_resolve_host_label)"
export TEE_LOG=0
export SCP_TO_93=0

SESSION_DIR="$(inference_session_dir)"
inference_ensure_dir "$SESSION_DIR"
PID_FILE="$SESSION_DIR/recorder-${HOST_LABEL}.pid"
META_FILE="$SESSION_DIR/recorder-${HOST_LABEL}.meta"

UNIT_NAME="$(inference_recorder_unit_name)"

if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "inference-record: already running pid=$old_pid host=$HOST_LABEL session=$inference_LOG_SESSION_ID"
    exit 0
  fi
fi
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
  echo "inference-record: already running unit=$UNIT_NAME host=$HOST_LABEL session=$inference_LOG_SESSION_ID"
  exit 0
fi

# nohup alone does not survive systemd-logind KillUserProcesses=yes tearing down the
# sudo/SSH session's cgroup on exit (official: freedesktop.org/software/systemd/man/latest/logind.conf.html).
# Prefer systemd-run: as root (via sudo) this starts a system-scope transient unit that is
# independent of any login session, so it is not killed when the launching session ends.
# WSL and some hosts expose systemd-run but deny non-interactive polkit auth - fall back to nohup.
_recorder_started=0
if command -v systemd-run >/dev/null 2>&1; then
  # --no-ask-password: fail fast under non-interactive SSH instead of hanging on polkit
  # (official: systemd-run(1)). Outer timeout is belt-and-suspenders if polkit still blocks.
  _sdr_cmd=(systemd-run --no-ask-password --unit="$UNIT_NAME" --collect --quiet \
    --setenv=ALFA_AI_REPO="$ALFA_AI_REPO" \
    --setenv=inference_LOG_SESSION_ID="$inference_LOG_SESSION_ID" \
    --setenv=HOST_LABEL="$HOST_LABEL" \
    --setenv=TEE_LOG="${TEE_LOG:-0}" \
    --setenv=SCP_TO_93="${SCP_TO_93:-0}" \
    --setenv=PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -- bash "$SCRIPT_DIR/record-inference-host-logs.sh")
  if command -v timeout >/dev/null 2>&1; then
    if timeout 15 "${_sdr_cmd[@]}" >>"$META_FILE" 2>&1; then
      _sdr_ok=1
    else
      _sdr_ok=0
    fi
  elif "${_sdr_cmd[@]}" >>"$META_FILE" 2>&1; then
    _sdr_ok=1
  else
    _sdr_ok=0
  fi
  if [[ "${_sdr_ok:-0}" -eq 1 ]]; then
    echo "systemd-run" >"$SESSION_DIR/recorder-${HOST_LABEL}.mode"
    echo "inference-record: started unit=$UNIT_NAME host=$HOST_LABEL session=$inference_LOG_SESSION_ID (errors only, survives session end)"
    _recorder_started=1
  else
    echo "inference-record: WARN systemd-run failed (no polkit/interactive auth?); falling back to nohup" >>"$META_FILE" 2>&1
  fi
fi
if [[ "$_recorder_started" -eq 0 ]]; then
  nohup env ALFA_AI_REPO="$ALFA_AI_REPO" inference_LOG_SESSION_ID="$inference_LOG_SESSION_ID" HOST_LABEL="$HOST_LABEL" \
    TEE_LOG="${TEE_LOG:-0}" SCP_TO_93="${SCP_TO_93:-0}" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash "$SCRIPT_DIR/record-inference-host-logs.sh" >>"$META_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  echo "nohup" >"$SESSION_DIR/recorder-${HOST_LABEL}.mode"
  echo "inference-record: started pid=$(cat "$PID_FILE") host=$HOST_LABEL session=$inference_LOG_SESSION_ID (errors only, nohup fallback)"
  echo "inference-record: WARN recorder uses nohup; may be killed early if the launching session ends (systemd-logind KillUserProcesses)" >&2
fi
if [[ -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER:$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$SESSION_DIR" 2>/dev/null || true
fi
echo "inference-record: log=$(inference_log_file)"