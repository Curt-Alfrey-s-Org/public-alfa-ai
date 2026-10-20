#!/usr/bin/env bash
# Build and publish @alfa-ai/chat-widget to the cluster Verdaccio registry.
# Run from a LAN host with npm + network to hub:4873 (e.g. apps or orchestrator/WSL).
#
# Prereq (one-time): npm adduser --registry http://hub --scope @alfa-ai
# Docs: deploy/npm-proxy/README.md, docs/ALFA_AI_CHAT_WIDGETS.md
set -euo pipefail

REGISTRY="${NPM_REGISTRY:-http://hub}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "${SCRIPT_DIR}/../packages/chat-widget" && pwd)"

echo "[publish] package: ${PKG_DIR}"
echo "[publish] registry: ${REGISTRY}"

# Fail fast if the registry is unreachable.
if ! curl -fsS --max-time 10 "${REGISTRY}/-/ping" >/dev/null 2>&1; then
  if ! curl -fsS --max-time 10 "${REGISTRY}" >/dev/null 2>&1; then
    echo "[publish] ERROR: registry ${REGISTRY} not reachable. Is Verdaccio up on hub?" >&2
    exit 1
  fi
fi

cd "${PKG_DIR}"
if [ -f package-lock.json ]; then
  npm ci --registry "${REGISTRY}"
else
  npm install --registry "${REGISTRY}"
fi
npm run build
npm publish --registry "${REGISTRY}"

echo "[publish] done. Version: $(node -p "require('./package.json').version")"
echo "[publish] consumers: bump @alfa-ai/chat-widget then rebuild each frontend."
