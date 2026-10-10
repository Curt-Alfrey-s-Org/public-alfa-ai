#!/usr/bin/env bash
# Record inference errors only: filtered docker logs, die/oom events, TCP probe failures,
# kernel GPU driver lines (Xid / NVRM), and lactd journal on LACT hosts.
#
# Usage:
#   inference_LOG_SESSION_ID=20260702-120000 HOST_LABEL=148 bash .../record-inference-host-logs.sh
#   TEE_LOG=1  — mirror error lines to stdout (optional live window)
#   SCP_TO_93=1 — copy session files to operator@orchestrator on exit
set -euo pipefail

_rp27_self="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_rp27_self%/*}"
[[ "$SCRIPT_DIR" == "$_rp27_self" || -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
# shellcheck source=inference-log-helpers.sh
source "$SCRIPT_DIR/inference-log-helpers.sh"

TAIL_LINES="${TAIL_LINES:-500}"
TEE_LOG="${TEE_LOG:-0}"
SCP_TO_93="${SCP_TO_93:-0}"
WAIT_SEC="${inference_LOG_WAIT_SEC:-15}"
PROBE_SEC="${inference_PROBE_INTERVAL_SEC:-60}"
THROTTLE_SEC="${inference_GPU_THROTTLE_INTERVAL_SEC:-120}"
ERR_RE="$(inference_error_grep_pattern)"
GPU_KERN_RE="$(inference_gpu_kernel_grep_pattern)"

export inference_LOG_SESSION_ID="${inference_LOG_SESSION_ID:-$(inference_session_id)}"

LOG_FILE="$(inference_log_file)"
SESSION_DIR="$(inference_session_dir)"
HOST_LABEL="$(inference_resolve_host_label)"
inference_ensure_dir "$SESSION_DIR"

echo "inference-record: host=$HOST_LABEL session=$inference_LOG_SESSION_ID (errors only)"
echo "inference-record: log_file=$LOG_FILE"

inference_write_error_baseline "$LOG_FILE"

pids=()
cleanup() {
  local sig="${1:-EXIT}"
  {
    echo ""
    echo "======== recorder stopped signal=$sig at $(date -Iseconds 2>/dev/null || date) ========"
  } >>"$LOG_FILE"
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  if [[ "$SCP_TO_93" == "1" ]]; then
    inference_scp_to_93 || true
  fi
  echo "inference-record: stopped ($HOST_LABEL) -> $LOG_FILE"
}
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM
trap 'cleanup EXIT' EXIT

emit_line() {
  local line="$1"
  printf '%s\n' "$line" >>"$LOG_FILE"
  if [[ "$TEE_LOG" == "1" ]]; then
    printf '%s\n' "$line"
  fi
}

follow_container_errors() {
  local name="$1"
  inference_dc logs --timestamps --tail "$TAIL_LINES" "$name" 2>&1 \
    | grep --line-buffered -iE "$ERR_RE" || true
  inference_dc logs --timestamps --tail 0 -f "$name" 2>&1 \
    | grep --line-buffered -iE "$ERR_RE" || true
}

watch_docker_events() {
  inference_dc events --format '{{.Time}} {{.Actor.Attributes.name}} {{.Action}} exit={{.Actor.Attributes.exitCode}}' \
    --filter event=die --filter event=oom --filter event=kill 2>/dev/null \
    | while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      emit_line "[docker-event] $line"
    done
}

watch_tcp_failures() {
  while true; do
    local hp host port
    for hp in $(inference_probe_targets); do
      host="${hp%:*}"
      port="${hp#*:}"
      if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w2 "$host" "$port" 2>/dev/null; then
          emit_line "[probe] TCP FAIL $hp at $(date -Iseconds 2>/dev/null || date)"
        fi
      fi
    done
    sleep "$PROBE_SEC"
  done
}

watch_kernel_gpu_errors() {
  local jcmd=""
  if command -v journalctl >/dev/null 2>&1; then
    if journalctl -kf -k --no-pager -n 0 >/dev/null 2>&1; then
      jcmd="journalctl -kf -k --no-pager"
    elif journalctl -kf --no-pager -n 0 >/dev/null 2>&1; then
      jcmd="journalctl -kf --no-pager"
    fi
  fi
  if [[ -n "$jcmd" ]]; then
    $jcmd 2>/dev/null | grep --line-buffered -iE "$GPU_KERN_RE" | while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      emit_line "[kernel] $line"
    done
    return 0
  fi
  if command -v dmesg >/dev/null 2>&1; then
    dmesg -w 2>/dev/null | grep --line-buffered -iE "$GPU_KERN_RE" | while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      emit_line "[dmesg] $line"
    done
  fi
}

watch_lactd_errors() {
  if ! command -v journalctl >/dev/null 2>&1; then
    return 0
  fi
  if ! systemctl is-active lactd >/dev/null 2>&1; then
    return 0
  fi
  journalctl -u lactd -kf --no-pager 2>/dev/null \
    | grep --line-buffered -iE 'error|fail|fatal|warn|NVRM|Xid|cuda' \
    | while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      emit_line "[lactd] $line"
    done
}

watch_gpu_throttle() {
  while true; do
    if command -v nvidia-smi >/dev/null 2>&1; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if echo "$line" | grep -qiE 'Not Active|N/A|Idle'; then
          continue
        fi
        emit_line "[nvidia-throttle] $line at $(date -Iseconds 2>/dev/null || date)"
      done < <(nvidia-smi --query-gpu=index,name,clocks_throttle_reasons.active --format=csv,noheader 2>/dev/null || true)
    fi
    sleep "$THROTTLE_SEC"
  done
}

wait_for_containers() {
  local -a running=()
  while true; do
    mapfile -t running < <(inference_running_containers || true)
    if [[ ${#running[@]} -gt 0 ]]; then
      printf '%s\n' "${running[@]}"
      return 0
    fi
    sleep "$WAIT_SEC"
  done
}

watch_docker_events &
pids+=("$!")

watch_tcp_failures &
pids+=("$!")

watch_kernel_gpu_errors &
pids+=("$!")

watch_lactd_errors &
pids+=("$!")

watch_gpu_throttle &
pids+=("$!")

mapfile -t RUNNING < <(wait_for_containers)
emit_line "[recorder] watching errors on ${#RUNNING[@]} containers: ${RUNNING[*]}"

for name in "${RUNNING[@]}"; do
  (
    follow_container_errors "$name" | while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      emit_line "[${name}] ${line}"
    done
  ) &
  pids+=("$!")
done

wait