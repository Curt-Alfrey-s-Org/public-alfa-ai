#!/usr/bin/env bash
# Sync a hub/worker git clone to origin/<branch> as the repo owner (not root).
#
# Use on hub when:
#   - sudo deploy.sh git pull fails (root has no GitHub SSH key)
#   - nfs/rsync left root-owned files under deploy/ (git reset Permission denied)
#   - hub rsync duplicated commit files as "local changes"
#
# Usage:
#   bash deploy/cluster-members/_common/git-sync-repo-clone.sh [REPO_DIR] [BRANCH]
#
# Official git behavior: fetch updates refs locally; reset --hard matches tree
# (https://git-scm.com/docs/git-reset). Run git as the clone owner per file ownership.
set -euo pipefail

REPO_DIR="${1:-/mnt/hub/alfa-ai/repo/alfa-ai}"
BRANCH="${2:-main}"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: not a git repo: $REPO_DIR" >&2
  exit 1
fi

REPO_OWNER="$(stat -c '%U' "$REPO_DIR/.git" 2>/dev/null || stat -f '%Su' "$REPO_DIR/.git")"
REPO_GROUP="$(stat -c '%G' "$REPO_DIR/.git" 2>/dev/null || stat -f '%Sg' "$REPO_DIR/.git")"
RUNNER="$(id -un)"

run_as_owner() {
  if [[ "$RUNNER" == "$REPO_OWNER" ]]; then
    bash -c "$1"
  else
    sudo -u "$REPO_OWNER" -H bash -c "$1"
  fi
}

# Root-owned paths from sudo rsync/cp into the NFS clone block git unlink on reset.
fix_root_owned_deploy_paths() {
  if [[ "$RUNNER" != root ]]; then
    return 0
  fi
  local paths=(
    "$REPO_DIR/deploy/aria2"
    "$REPO_DIR/deploy/ml-wheels/build-contexts"
  )
  local p
  for p in "${paths[@]}"; do
    if [[ -e "$p" ]]; then
      chown -R "$REPO_OWNER:$REPO_GROUP" "$p" 2>/dev/null || true
    fi
  done
}

fix_root_owned_deploy_paths

REMOTE="origin"
REF="$REMOTE/$BRANCH"

echo "== git-sync-repo-clone =="
echo "  repo:   $REPO_DIR"
echo "  branch: $BRANCH"
echo "  owner:  $REPO_OWNER (runner: $RUNNER)"

run_as_owner "cd '$REPO_DIR' && git fetch $REMOTE $BRANCH"
run_as_owner "cd '$REPO_DIR' && git reset --hard '$REF'"
run_as_owner "cd '$REPO_DIR' && git clean -fd"

SHORT="$(run_as_owner "cd '$REPO_DIR' && git rev-parse --short HEAD")"
echo "  HEAD:   $SHORT ($REF)"
echo "git-sync-repo-clone OK"
