#!/usr/bin/env bash
# Pull inference error log files from cluster hosts into orchestrator analysis dir.
# Run on orchestrator (Git Bash/WSL) after a start/stop cycle.
#
# Usage:
#   bash deploy/cluster-members/_common/fetch-inference-session-to-93.sh [session_id]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SESSION_ID="${1:-${inference_LOG_SESSION_ID:-}}"
SSH_JUMP="${inference_SSH_JUMP:-operator@orchestrator}"

if [[ -z "$SESSION_ID" && -f "$REPO_ROOT/logs/inference-sessions/.current-session" ]]; then
  SESSION_ID="$(tr -d '\r\n' <"$REPO_ROOT/logs/inference-sessions/.current-session")"
fi
if [[ -z "$SESSION_ID" ]]; then
  echo "ERROR: pass session_id or set inference_LOG_SESSION_ID" >&2
  exit 1
fi

DEST="${inference_LOG_DIR:-$REPO_ROOT/logs/inference-sessions}/$SESSION_ID"
mkdir -p "$DEST"

pull_host() {
  local label="$1" ssh_target="$2" remote_repo="$3"
  local remote_dir="$remote_repo/logs/inference-sessions/$SESSION_ID"
  local remote_file="$remote_dir/inference-${label}-errors.log"
  echo "== fetch $label from $ssh_target:$remote_file =="
  if scp -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
       "${ssh_target}:${remote_file}" "$DEST/" 2>/dev/null; then
    echo "  OK inference-${label}-errors.log"
  else
    echo "  WARN missing inference-${label}-errors.log on $label"
  fi
}

pull_host 100 operator@orchestrator /home/operator/alfa-ai
pull_host 148 operator@orchestrator /home/operator/alfa-ai

echo "== fetch 111 via inference jump =="
remote111="/mnt/hub/alfa-ai/repo/alfa-ai/logs/inference-sessions/$SESSION_ID/inference-111-errors.log"
if ssh -o BatchMode=yes -o ConnectTimeout=20 "$SSH_JUMP" \
     "ssh -o BatchMode=yes -o ConnectTimeout=15 -i ~/.ssh/id_ed25519_cluster operator@hub 'cat ${remote111} 2>/dev/null || sudo -n cat ${remote111} 2>/dev/null'" \
     >"$DEST/inference-111-errors.log" 2>/dev/null \
   && [[ -s "$DEST/inference-111-errors.log" ]]; then
  echo "  OK inference-111-errors.log"
else
  rm -f "$DEST/inference-111-errors.log" 2>/dev/null || true
  echo "  WARN missing inference-111-errors.log on 111"
fi

echo ""
echo "Session dir on orchestrator: $DEST"
echo "Analyze: cat $DEST/inference-*-errors.log"