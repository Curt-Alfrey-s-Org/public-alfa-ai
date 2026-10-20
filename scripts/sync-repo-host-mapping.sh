#!/usr/bin/env bash
#
# sync-repo-host-mapping.sh
#
# Purpose:
#   Copy the authoritative REPO_HOST_MAPPING.md from the alfa-ai master
#   into every sibling repo that should carry a copy of the cluster layout.
#
# Why:
#   So that `git pull` in any repo (market-pie5-bot, atems, contracts-bot, etc.)
#   automatically gives operators the current "where is everything running" map.
#
# Run on any host that has sibling repo clones colocated (often apps).
# Commit + push each updated repo from the host that owns that clone.
#
# Usage:
#   cd /home/operator/alfa-ai
#   bash scripts/sync-repo-host-mapping.sh
#
# After running, you still need to:
#   git add + commit + push inside each target repo.
#
set -euo pipefail

BASE_DIR="/home/operator"
MASTER="$BASE_DIR/alfa-ai/docs/REPO_HOST_MAPPING.md"

if [[ ! -f "$MASTER" ]]; then
  echo "ERROR: Master file not found: $MASTER"
  echo "Are you running this on apps with the alfa-ai clone at $BASE_DIR/alfa-ai ?"
  exit 1
fi

# List of repos that should carry a copy of the mapping.
# Add new ones here when a new dedicated VM + repo is created.
REPOS=(
  market-pie5-bot
  atems
  contracts-bot
  credit-check-bot
  rv-auto-finder
  rankings-bot
  USPBF
  example-site-perch
  monitoring
  auth-service
  alfaqd-website
  # Add more repo directory names as needed
)

echo "==> Syncing REPO_HOST_MAPPING.md from alfa-ai master to sibling repos"
echo "    Master: $MASTER"
echo

for repo in "${REPOS[@]}"; do
  target_dir="$BASE_DIR/$repo/docs"
  target_file="$target_dir/REPO_HOST_MAPPING.md"

  mkdir -p "$target_dir"
  cp -v "$MASTER" "$target_file"
done

echo
echo "==> Done copying."
echo
echo "Next steps (run these on apps for each repo you want to update):"
echo
echo "  cd $BASE_DIR/market-pie5-bot"
echo "  git add docs/REPO_HOST_MAPPING.md"
echo "  git commit -m 'docs: sync REPO_HOST_MAPPING.md (cluster layout)'"
echo "  git push origin main"
echo
echo "Repeat for the other repos above."
echo
echo "Then on every host (including the new VMs):"
echo "  cd /path/to/the/repo && git pull --ff-only origin main"
