#!/usr/bin/env bash
# Fetch origin/main when GitHub is unreachable but the hub hub git object store is on LAN.
#
# Usage (from repo root on a worker):
#   bash deploy/cluster-members/_common/sync-git-origin-hub-lan.sh [/path/to/clone]
#
# Env (optional):
#   ALFA_AI_HUB_GIT_FILE   file:// URL or path to .git dir (auto-detected if unset)
#   ALFA_AI_HUB_GIT_SSH    fallback, e.g. ssh://operator@orchestrator/home/operator/alfa-ai/.git
#
# Official git remote URLs: https://git-scm.com/docs/git-remote
set -euo pipefail

REPO="${1:-${ALFA_AI_REPO:-$HOME/alfa-ai}}"
if [[ ! -d "$REPO/.git" ]]; then
  echo "ERROR: not a git repo: $REPO" >&2
  exit 1
fi

cd "$REPO"

hub_file_url() {
  if [[ -n "${ALFA_AI_HUB_GIT_FILE:-}" ]]; then
    case "$ALFA_AI_HUB_GIT_FILE" in
      file://*) echo "$ALFA_AI_HUB_GIT_FILE" ;;
      *) echo "file://$ALFA_AI_HUB_GIT_FILE" ;;
    esac
    return 0
  fi
  if [[ -d /mnt/cluster/repo/alfa-ai/.git ]]; then
    echo "file:///mnt/cluster/repo/alfa-ai/.git"
    return 0
  fi
  if [[ -d /mnt/hub/alfa-ai/repo/alfa-ai/.git ]]; then
    echo "file:///mnt/hub/alfa-ai/repo/alfa-ai/.git"
    return 0
  fi
  return 1
}

try_fetch() {
  git fetch origin main
}

if try_fetch 2>/dev/null; then
  git reset --hard origin/main
  exit 0
fi

echo "WARN: git fetch origin main failed (GitHub DNS or SSH); trying hub LAN origin" >&2

if url="$(hub_file_url 2>/dev/null)"; then
  git remote set-url origin "$url"
  git fetch origin main
  git reset --hard origin/main
  echo "OK: synced via hub file origin ($url)"
  exit 0
fi

if [[ -n "${ALFA_AI_HUB_GIT_SSH:-}" ]]; then
  git remote set-url origin "$ALFA_AI_HUB_GIT_SSH"
  git fetch origin main
  git reset --hard origin/main
  echo "OK: synced via hub SSH origin ($ALFA_AI_HUB_GIT_SSH)"
  exit 0
fi

echo "ERROR: no hub LAN origin found (/mnt/cluster or /mnt/hub/alfa-ai) and fetch failed" >&2
exit 1
