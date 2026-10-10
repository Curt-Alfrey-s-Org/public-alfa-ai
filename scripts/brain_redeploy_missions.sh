#!/usr/bin/env bash
# One-shot brain + Missions worker rollout on hub (hub / hub).
#
# Steps:
#   1) git pull --ff-only
#   2) brain_redeploy_api.sh (build/recreate API + brain_verify)
#   3) start alfa-ai-worker (compose profile agent-worker)
#   4) verify worker container + recent logs
#
# Always tees a timestamped log under the hub agent-audit-logs tree.
# Push SCP hub -> orchestrator is OFF by default: Windows OpenSSH inbound from hub
# often times out. Agents/operators on orchestrator should pull instead:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pull-brain-redeploy-log-from-111.ps1
#
# After git pull, the script re-execs itself with --skip-pull so the pulled
# body (exit codes, SCP default) actually runs (bash keeps the pre-pull script
# in memory otherwise).
#
# Usage (From hub as operator):
#   cd /mnt/hub/alfa-ai/repo/alfa-ai
#   bash scripts/brain_redeploy_missions.sh
#
#   sudo bash scripts/brain_redeploy_missions.sh   # docker via sudo; git as SUDO_USER
#   (Usually unnecessary: _alfa_compose_env.sh selects sudo docker when needed.)
#
# Flags:
#   --skip-pull       Do not git pull (also set by post-pull re-exec)
#   --skip-redeploy   Skip API rebuild (worker start + verify only)
#   --worker-only     Alias for --skip-pull --skip-redeploy
#   --scp             Attempt scp log to orchestrator (usually fails; prefer pull script)
#   --no-scp          Explicitly skip scp (default)
#
# Env:
#   SCP_TO_93=0|1                 default 0 (pull from orchestrator instead)
#   SCP_HOST=operator@orchestrator
#   SCP_REMOTE_DIR=C:/Users/operator/alfa-ai/logs/brain-redeploy
#   SCP_IDENTITY=/path/to/key     optional ssh -i
#   LOG_DIR=...                   default hub agent-audit-logs/brain-redeploy
#   ALFA_REDEPLOY_MISSIONS_LOG    reuse log path across post-pull re-exec
#
# Official Compose profiles: https://docs.docker.com/compose/how-tos/profiles/
# OpenSSH scp: https://man.openbsd.org/scp.1
# Members pull (scp-direction): diagnostic host initiates transfer.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORIG_ARGS=("$@")

DO_PULL=1
DO_REDEPLOY=1
# Default off: hub -> orchestrator:22 usually times out; pull from orchestrator instead.
DO_SCP=0
WORKER_LOG_LINES="${WORKER_LOG_LINES:-30}"

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
    --skip-pull) DO_PULL=0 ;;
    --skip-redeploy) DO_REDEPLOY=0 ;;
    --scp) DO_SCP=1 ;;
    --no-scp) DO_SCP=0 ;;
    --worker-only)
      DO_PULL=0
      DO_REDEPLOY=0
      ;;
    *)
      echo "Unknown flag: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

# Env overrides flags when set (1/true enables, 0/false disables).
case "${SCP_TO_93:-}" in
  1|true|yes) DO_SCP=1 ;;
  0|false|no) DO_SCP=0 ;;
esac

TS="$(date -u +%Y%m%d-%H%M%S)"
HOST_SHORT="$(hostname -s 2>/dev/null || echo hub)"
LOG_DIR="${LOG_DIR:-/mnt/hub/alfa-ai/agent-audit-logs/brain-redeploy}"
mkdir -p "$LOG_DIR" 2>/dev/null || {
  LOG_DIR="${REPO_ROOT}/logs/brain-redeploy"
  mkdir -p "$LOG_DIR"
}
if [[ -n "${ALFA_REDEPLOY_MISSIONS_LOG:-}" ]]; then
  LOG_FILE="$ALFA_REDEPLOY_MISSIONS_LOG"
else
  LOG_FILE="${LOG_DIR}/brain-redeploy-missions-${HOST_SHORT}-${TS}.log"
fi

run_as_clone_owner() {
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    sudo -u "$SUDO_USER" -H "$@"
  else
    "$@"
  fi
}

scp_log_to_93() {
  local scp_host="${SCP_HOST:-operator@orchestrator}"
  local remote_dir="${SCP_REMOTE_DIR:-C:/Users/operator/alfa-ai/logs/brain-redeploy}"
  local identity="${SCP_IDENTITY:-}"
  # ConnectTimeout: https://man.openbsd.org/ssh_config.5
  local -a ssh_base=(
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15 -o ConnectionAttempts=1
  )
  local -a scp_base=(
    scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15 -o ConnectionAttempts=1
  )
  if [[ -n "$identity" && -f "$identity" ]]; then
    ssh_base+=(-i "$identity")
    scp_base+=(-i "$identity")
  fi

  {
    echo ""
    echo "== scp log to orchestrator =="
    echo "local_log=$LOG_FILE"
    echo "remote=${scp_host}:${remote_dir}/"
  } >>"$LOG_FILE"

  # Windows OpenSSH often uses PowerShell; Linux accepts mkdir -p.
  "${ssh_base[@]}" "$scp_host" \
    "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path '${remote_dir}' | Out-Null\"" \
    >>"$LOG_FILE" 2>&1 \
    || "${ssh_base[@]}" "$scp_host" "mkdir -p '${remote_dir}'" >>"$LOG_FILE" 2>&1 \
    || true

  if "${scp_base[@]}" "$LOG_FILE" "${scp_host}:${remote_dir}/" >>"$LOG_FILE" 2>&1; then
    {
      echo "SCP_OK basename=$(basename "$LOG_FILE")"
      echo "On orchestrator read: ${remote_dir}/$(basename "$LOG_FILE")"
    } >>"$LOG_FILE"
    echo "SCP_OK -> ${scp_host}:${remote_dir}/$(basename "$LOG_FILE")"
  else
    {
      echo "SCP_FAIL (log remains on hub at $LOG_FILE)"
      echo "Preferred: on orchestrator pull with scripts/pull-brain-redeploy-log-from-111.ps1"
    } >>"$LOG_FILE"
    echo "SCP_FAIL - log left at $LOG_FILE" >&2
  fi
}

finish_and_scp() {
  local rc="$1"
  {
    echo ""
    echo "== brain_redeploy_missions: finished exit=${rc} =="
    echo "log=$LOG_FILE"
    if [[ "$rc" -ne 0 ]]; then
      echo "HINT: grep -nE 'FAIL|ERROR|hard error|brain_verify|note_fail' \"$LOG_FILE\""
    else
      echo "POST-REDEPLOY monitoring (monitor): brain_redeploy_api.sh already tried SSH bearer refresh."
      echo "  If that WARN'd (no key on hub), next cluster start from orchestrator refreshes after brain health."
      echo "  Manual: cd /home/operator/monitoring && bash scripts/refresh-alfa-ai-prometheus-bearer.sh"
    fi
  } | tee -a "$LOG_FILE"
  if [[ "$DO_SCP" -eq 1 ]]; then
    scp_log_to_93 || true
  else
    {
      echo "SCP skipped (default). Log on hub: $LOG_FILE"
      echo "On orchestrator: powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\pull-brain-redeploy-log-from-111.ps1"
    } | tee -a "$LOG_FILE"
  fi
  return "$rc"
}

# Pull + re-exec before tee so the pulled script body owns the deploy steps.
# Bash exec: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
if [[ "$DO_PULL" -eq 1 && "${ALFA_REDEPLOY_MISSIONS_REEXEC:-}" != "1" ]]; then
  {
    echo "== brain_redeploy_missions: pull =="
    echo "repo=$REPO_ROOT"
    echo "log=$LOG_FILE"
    echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[1/5] git pull --ff-only origin main"
  } | tee -a "$LOG_FILE"
  if ! (
    cd "$REPO_ROOT"
    run_as_clone_owner git pull --ff-only origin main
  ) 2>&1 | tee -a "$LOG_FILE"; then
    echo "[1/5] git pull FAILED" | tee -a "$LOG_FILE"
    finish_and_scp 1
    exit 1
  fi
  echo "[1/5] re-exec after pull (use on-disk script body)" | tee -a "$LOG_FILE"
  export ALFA_REDEPLOY_MISSIONS_REEXEC=1
  export ALFA_REDEPLOY_MISSIONS_LOG="$LOG_FILE"
  exec bash "$SCRIPT_DIR/brain_redeploy_missions.sh" --skip-pull "${ORIG_ARGS[@]}"
fi

main() {
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/_alfa_compose_env.sh"

  echo "== brain_redeploy_missions: start =="
  echo "repo=$REPO_ROOT"
  echo "log=$LOG_FILE"
  echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "docker=${ALFA_AI_DOCKER[*]}"
  if [[ "${ALFA_REDEPLOY_MISSIONS_REEXEC:-}" == "1" ]]; then
    echo "[1/5] git pull done (pre-re-exec)"
  else
    echo "[1/5] git pull skipped"
  fi

  echo "[2/5] ensure-runtime-schema (runs/tasks tables)"
  if ! bash "$SCRIPT_DIR/ensure-runtime-schema.sh"; then
    echo "[2/5] ensure-runtime-schema FAILED"
    return 1
  fi

  if [[ "$DO_REDEPLOY" -eq 1 ]]; then
    echo "[3/5] brain_redeploy_api.sh"
    # Capture exit status in a plain assignment (not `if !`).
    # Bash exit status: https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html
    local redeploy_rc=0
    bash "$SCRIPT_DIR/brain_redeploy_api.sh" --skip-pull
    redeploy_rc=$?
    if [[ "$redeploy_rc" -ne 0 ]]; then
      echo "[3/5] brain_redeploy_api FAILED rc=${redeploy_rc}"
      echo "--- brain_verify re-run (capture hard errors) ---"
      bash "$SCRIPT_DIR/brain_verify.sh" || true
      return "$redeploy_rc"
    fi
  else
    echo "[3/5] brain_redeploy_api skipped"
  fi

  echo "[4/5] start alfa-ai-worker (profile agent-worker)"
  alfa_run_compose --profile agent-worker up -d alfa-ai-worker || return $?

  echo "[5/5] verify worker"
  "${ALFA_AI_DOCKER[@]}" ps --filter name=alfa-ai-worker --format '{{.Names}} {{.Status}}'
  echo "--- recent worker logs ---"
  "${ALFA_AI_DOCKER[@]}" logs alfa-ai-worker --tail "$WORKER_LOG_LINES" || true

  echo ""
  echo "== brain_redeploy_missions: body ok =="
  echo "Next: hard-refresh Admin -> Missions; Ask ALFa: Clear stuck missions"
  return 0
}

# Tee console + file (GNU coreutils tee).
# https://www.gnu.org/software/coreutils/manual/html_node/tee-invocation.html
set -o pipefail
main "$@" 2>&1 | tee -a "$LOG_FILE"
MAIN_RC="${PIPESTATUS[0]}"
finish_and_scp "$MAIN_RC"
exit "$MAIN_RC"
