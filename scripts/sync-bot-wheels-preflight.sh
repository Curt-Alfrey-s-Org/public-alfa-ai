#!/usr/bin/env bash
# Best-effort preflight: pull bot/app PyPI wheels from the hub hub hub into
# each repo's build-contexts/wheels-bots/ before a Docker build.
#
# NON-FATAL by design: the bot Dockerfiles use `pip install --find-links /tmp/wheels`
# (not --no-index / PIP_OFFLINE), so when the hub is unavailable the build still
# succeeds via public PyPI + the /srv/dep-cache BuildKit cache. We therefore sync
# when the hub is reachable and skip with a clear notice otherwise — mirroring the
# warn-and-continue pattern in deploy/cluster-members/hub/deploy.sh.
#
# The underlying sync (scripts/sync-bot-wheels-from-hub.sh) fans out to ALL bot
# repos in one rsync pass, so calling this from any one repo's build also refreshes
# the others.
#
# Usage (from a bot repo build script; alfa-ai is a sibling checkout):
#   ALFA_AI_ROOT="${ALFA_AI_ROOT:-$REPO_ROOT/../alfa-ai}"
#   [ -f "$ALFA_AI_ROOT/scripts/sync-bot-wheels-preflight.sh" ] && \
#     bash "$ALFA_AI_ROOT/scripts/sync-bot-wheels-preflight.sh" || true
#
# Docs: docs/HUB_ARTIFACTS.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALFA_AI_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNC="${ALFA_AI_ROOT}/scripts/sync-bot-wheels-from-hub.sh"
CLUSTER_WHEELS_BOTS="${CLUSTER_WHEELS_BOTS:-/mnt/cluster/wheels/bots}"

note() { echo "[wheels-preflight] $*" >&2; }

if [[ ! -f "$SYNC" ]]; then
  note "sync-bot-wheels-from-hub.sh not found at ${SYNC}; skipping (build uses PyPI/cache)."
  exit 0
fi

# Only the NFS-mounted hub needs a mount check; a custom CLUSTER_WHEELS_BOTS path
# (e.g. a local mirror) is used as-is.
if [[ "$CLUSTER_WHEELS_BOTS" == /mnt/cluster/* ]] && ! mountpoint -q /mnt/cluster 2>/dev/null; then
  note "hub hub (/mnt/cluster) not mounted; skipping sync (build uses PyPI/cache)."
  note "To enable the hub: sudo bash ${ALFA_AI_ROOT}/scripts/mount_nfs_models.sh"
  exit 0
fi

if [[ ! -d "$CLUSTER_WHEELS_BOTS" ]]; then
  note "hub wheel dir ${CLUSTER_WHEELS_BOTS} missing; skipping sync (build uses PyPI/cache)."
  exit 0
fi

note "syncing bot wheels from ${CLUSTER_WHEELS_BOTS} ..."
if ! CLUSTER_HUB_REQUIRED=1 bash "$SYNC"; then
  note "hub sync returned non-zero; continuing (build uses PyPI/cache)."
fi
exit 0
