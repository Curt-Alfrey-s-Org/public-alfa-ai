#!/usr/bin/env bash
# Copy bot/app PyPI wheels from hub hub into each repo build-context dir.
#
# Usage:
#   bash scripts/sync-bot-wheels-from-hub.sh
#
# Env:
#   WORKSPACE_ROOT    — parent of alfa-ai + bot repos (default: parent of alfa-ai)
#   CLUSTER_WHEELS_BOTS — hub dir (default: /mnt/cluster/wheels/bots)
#
# Target per repo: <repo>/build-contexts/wheels-bots/ (gitignored wheels).
# Also mirrors into alfa-ai/deploy/build-contexts/wheels-bots for docs/monoreference.
#
# Docs: docs/HUB_ARTIFACTS.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALFA_AI_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
: "${WORKSPACE_ROOT:=$(cd "${ALFA_AI_ROOT}/.." && pwd)}"
CLUSTER_WHEELS_BOTS="${CLUSTER_WHEELS_BOTS:-/mnt/cluster/wheels/bots}"
CLUSTER_INSTALLERS="${CLUSTER_INSTALLERS:-/mnt/cluster/installers}"

DEST_MIRROR="${ALFA_AI_ROOT}/deploy/build-contexts/wheels-bots"

needs_cluster() {
  [[ "$CLUSTER_WHEELS_BOTS" == /mnt/cluster/* ]]
}

if needs_cluster && [[ "${CLUSTER_HUB_REQUIRED:-1}" == "1" ]]; then
  if ! mountpoint -q /mnt/cluster 2>/dev/null; then
    echo "ERROR: /mnt/cluster not mounted — cannot sync bot wheels from hub." >&2
    echo "  sudo bash ${ALFA_AI_ROOT}/scripts/mount_nfs_models.sh" >&2
    exit 1
  fi
fi

if [[ ! -d "$CLUSTER_WHEELS_BOTS" ]]; then
  echo "ERROR: bot wheel hub missing at ${CLUSTER_WHEELS_BOTS}" >&2
  echo "  Seed on hub: sudo bash scripts/seed-bot-wheels-hub.sh" >&2
  exit 1
fi

sync_one_dest() {
  local dest="$1"
  mkdir -p "$dest"
  rsync -a --info=stats2 \
    --exclude='.pip-cache/' \
    --exclude='.tmp/' \
    "${CLUSTER_WHEELS_BOTS}/" "${dest}/"
}

echo "==> Bot wheels hub -> workspace (${CLUSTER_WHEELS_BOTS})"

BOT_REPOS=(
  rankings-bot
  market-pie5-bot
  contracts-bot
  credit-check-bot
  atems
  auth-service
  rv-auto-finder
)

for repo in "${BOT_REPOS[@]}"; do
  dest="${WORKSPACE_ROOT}/${repo}/build-contexts/wheels-bots"
  echo "==> rsync -> ${dest}"
  sync_one_dest "$dest"
done

echo "==> rsync -> ${DEST_MIRROR} (alfa-ai mirror)"
mkdir -p "${DEST_MIRROR}"
sync_one_dest "${DEST_MIRROR}"

if [[ -d "${CLUSTER_INSTALLERS}/docker-cli" ]] && [[ "$(ls -A "${CLUSTER_INSTALLERS}/docker-cli" 2>/dev/null)" ]]; then
  rbd="${WORKSPACE_ROOT}/rankings-bot/build-contexts/docker-cli"
  echo "==> rsync Docker CLI tarball -> ${rbd}"
  mkdir -p "${rbd}"
  rsync -a --info=stats2 "${CLUSTER_INSTALLERS}/docker-cli/" "${rbd}/"
else
  echo "WARN: no hub Docker CLI at ${CLUSTER_INSTALLERS}/docker-cli — rankings Dockerfile.base needs curl fallback or run seed-docker-cli-hub.sh" >&2
fi

echo "Done. Dockerfiles use COPY build-contexts/wheels-bots + pip --find-links /tmp/wheels."
