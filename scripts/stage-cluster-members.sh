#!/usr/bin/env bash
# Stage per-member deploy folders to the hub SMB hub (\\hub\temp\cluster_members).
#
# Run on hub (hub) with write access to the hub dataset, or on orchestrator via
# scripts/stage-cluster-members.ps1 (preferred on Windows).
#
# Usage (on hub after git pull):
#   setopt interactivecomments
#   cd /mnt/hub/alfa-ai/repo/alfa-ai
#   sudo bash scripts/stage-cluster-members.sh
#
# Requires: rsync, git. Hub path defaults to /mnt/hub/alfa-ai/smb-scratch/cluster_members.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HUB_ROOT="${HUB_ROOT:-/mnt/hub/alfa-ai}"
DEST="${SMB_CLUSTER_MEMBERS:-$HUB_ROOT/smb-scratch/cluster_members}"
CLUSTER_SRC="$REPO_ROOT/deploy/cluster-members"

log() { printf '== %s\n' "$*"; }

if [[ ! -d "$CLUSTER_SRC" ]]; then
  echo "FAIL: $CLUSTER_SRC not found" >&2
  exit 1
fi

if [[ ! -w "$DEST" ]] && [[ "$(id -u)" -ne 0 ]]; then
  echo "FAIL: $DEST not writable — re-run with sudo on hub:" >&2
  echo "  sudo bash scripts/stage-cluster-members.sh" >&2
  exit 1
fi

log "Stage cluster members"
echo "  Repo: $REPO_ROOT"
echo "  Dest: $DEST"
echo ""

mkdir -p "$DEST"

log "Copying per-member folders"
for d in "$CLUSTER_SRC"/*/; do
  name="$(basename "$d")"
  [[ "$name" == "_common" ]] && continue
  mkdir -p "$DEST/$name"
  rsync -a --delete "$d" "$DEST/$name/"
  echo "  $name -> $DEST/$name"
done

log "Mirroring deploy/ + scripts/ to _common/repo/"
COMMON_REPO="$DEST/_common/repo"
mkdir -p "$COMMON_REPO"
rsync -a --delete \
  --exclude node_modules --exclude __pycache__ --exclude .venv --exclude venv --exclude logs \
  "$REPO_ROOT/deploy/" "$COMMON_REPO/deploy/"
rsync -a --delete \
  --exclude node_modules --exclude __pycache__ --exclude .venv --exclude venv --exclude logs \
  "$REPO_ROOT/scripts/" "$COMMON_REPO/scripts/"

log "Staging complete"
echo ""
echo "Win workers deploy from SMB:"
echo "  powershell -NoProfile -ExecutionPolicy Bypass -File \\\\hub\\temp\\cluster_members\\<gaming-worker-a-219|gaming-worker-c-59|gaming-worker-b-249>\\deploy.ps1"
echo ""
echo "Verify gaming-worker-a Dockge port fix:"
grep -n DockgePortDefault "$DEST/gaming-worker-a-219/run.ps1" 2>/dev/null || true
