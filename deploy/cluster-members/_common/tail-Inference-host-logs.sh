#!/usr/bin/env bash
# Tail inference + brain containers on this host (prefix per container name).
# When inference_LOG_SESSION_ID is set, records errors only to logs/inference-sessions/ and SCPs to orchestrator on exit.
#
# Usage:
#   bash deploy/cluster-members/_common/tail-inference-host-logs.sh
#   inference_LOG_SESSION_ID=20260702-120000 HOST_LABEL=148 TEE_LOG=1 bash .../tail-inference-host-logs.sh
#   HOST_LABEL=148 TAIL_LINES=200 bash .../tail-inference-host-logs.sh
#
# Run in a dedicated terminal during Start-Stop-AlfaAi.ps1 start/stop.
set -euo pipefail

_rp27_self="${BASH_SOURCE[0]}"
SCRIPT_DIR="${_rp27_self%/*}"
[[ "$SCRIPT_DIR" == "$_rp27_self" || -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

if [[ -n "${inference_LOG_SESSION_ID:-}" ]]; then
  export TEE_LOG="${TEE_LOG:-1}"
  export SCP_TO_93="${SCP_TO_93:-1}"
  exec bash "$SCRIPT_DIR/record-inference-host-logs.sh"
fi

TAIL_LINES="${TAIL_LINES:-100}"
HOST_LABEL="${HOST_LABEL:-$(hostname -s)}"

# shellcheck source=inference-log-helpers.sh
source "$SCRIPT_DIR/inference-log-helpers.sh"

mapfile -t RUNNING < <(inference_running_containers || true)

if [[ ${#RUNNING[@]} -eq 0 ]]; then
  echo "No inference/brain containers running on $HOST_LABEL yet."
  echo "Start the cluster cycle, or Ctrl+C to exit this tail."
  sleep 10
  exec "$0"
fi

echo "== tail-inference-host-logs: $HOST_LABEL (${#RUNNING[@]} containers) =="
echo "Containers: ${RUNNING[*]}"
echo "TIP: set inference_LOG_SESSION_ID to record + SCP to orchestrator on exit."
echo "Stop with Ctrl+C."
echo ""

pids=()
cleanup() {
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

for name in "${RUNNING[@]}"; do
  (
    inference_dc logs --timestamps --tail "$TAIL_LINES" -f "$name" 2>&1 | while IFS= read -r line; do
      printf '[%s] %s\n' "$name" "$line"
    done
  ) &
  pids+=("$!")
done

wait