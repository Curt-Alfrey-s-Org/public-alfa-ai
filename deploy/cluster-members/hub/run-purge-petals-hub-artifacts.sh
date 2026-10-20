#!/usr/bin/env bash
# Wrapper: purge Petals hub artifacts on hub with tee + optional SCP to inference.
# Operator on hub (operator):
#   cd /mnt/hub/alfa-ai/repo/alfa-ai && git pull --ff-only origin main
#   sudo bash deploy/cluster-members/hub/run-purge-petals-hub-artifacts.sh --dry-run
#   sudo bash deploy/cluster-members/hub/run-purge-petals-hub-artifacts.sh --apply
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
COMMON_ENV="${SCRIPT_DIR}/../_common/cluster-hub.env"
[[ -f "$COMMON_ENV" ]] && # shellcheck source=/dev/null
  source "$COMMON_ENV"

TS="$(date +%Y%m%d-%H%M%S)"
H="$(hostname -s 2>/dev/null || echo hub)"
LOG="/tmp/purge-petals-hub-${H}-${TS}.log"

cd "$REPO_ROOT"
sudo bash scripts/purge-petals-hub-artifacts-on-111.sh "$@" 2>&1 | tee "$LOG"

if [[ "${SCP_TO_BUILD_HOST:-0}" == "1" ]]; then
  SSH_HOST="${SSH_HOST:-operator@orchestrator}"
  REMOTE_DIR="${REMOTE_DIR:-/home/operator/alfa-ai/logs/hub-seed}"
  scp "$LOG" "${SSH_HOST}:${REMOTE_DIR}/" || echo "WARN: scp log to ${SSH_HOST} failed" >&2
fi

echo "Log: $LOG"
