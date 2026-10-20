#!/usr/bin/env bash
#
# sync-fleet-agent-rules.sh
#
# Copy fleet-wide Cursor agent rules from alfa-ai master into sibling repos.
# See docs/FLEET_AGENT_RULES.md
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.cursor/rules"

RULES=(
  agent-mistake-create-rule.mdc
  git-no-pull-on-push-host.mdc
  git-per-host-clone.mdc
  stable-releases-only.mdc
  fleet-agent-rules-source.mdc
)

ALFA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parent directory containing alfa-ai and sibling repo clones.
if [[ -n "${ALFA_SIBLING_REPOS_BASE:-}" ]]; then
  BASE_DIR="$ALFA_SIBLING_REPOS_BASE"
elif [[ -d "$ALFA_ROOT/../market-pie5-bot" ]]; then
  BASE_DIR="$(cd "$ALFA_ROOT/.." && pwd)"
elif [[ -d "/home/operator/alfa-ai" ]]; then
  BASE_DIR="/home/operator"
elif [[ -d "/mnt/c/Users/operator/alfa-ai" ]]; then
  BASE_DIR="/mnt/c/Users/operator"
else
  echo "ERROR: Set ALFA_SIBLING_REPOS_BASE to the directory that contains alfa-ai and sibling repos."
  exit 1
fi

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
  alfa-train
  victron-ble2mqtt-integration
)

for rule in "${RULES[@]}"; do
  if [[ ! -f "$MASTER_DIR/$rule" ]]; then
    echo "ERROR: Missing master rule: $MASTER_DIR/$rule"
    exit 1
  fi
done

echo "==> Syncing fleet agent rules from alfa-ai"
echo "    Master: $MASTER_DIR"
echo "    Base:   $BASE_DIR"
echo

for repo in "${REPOS[@]}"; do
  target_root="$BASE_DIR/$repo"
  if [[ ! -d "$target_root" ]]; then
    echo "SKIP (no clone): $repo"
    continue
  fi
  target_dir="$target_root/.cursor/rules"
  mkdir -p "$target_dir"
  for rule in "${RULES[@]}"; do
    cp -v "$MASTER_DIR/$rule" "$target_dir/$rule"
  done
done

echo
echo "==> Done. Commit + push each updated repo from its owning host."
