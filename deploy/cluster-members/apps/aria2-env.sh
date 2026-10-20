#!/usr/bin/env bash
# Ubuntu apps host — apps.
# Download policy: use hub (hub) aria2 RPC, not direct internet fallback.

export ALFA_AI_REPO="/home/operator/alfa-ai"
export ARIA2_MODE="rpc"
export ARIA2_RPC_URL="http://hub/jsonrpc"
# ARIA2_RPC_KEY is not stored in the repo: export it yourself (same value as the
# hub aria2 stack) before or after sourcing this file.
export ARIA2_RPC_KEY="${ARIA2_RPC_KEY:-}"
if [[ -z "$ARIA2_RPC_KEY" ]]; then
  echo 'WARN: ARIA2_RPC_KEY is not set; aria2 RPC calls will be rejected (see deploy/aria2/README.md).' >&2
fi
export ARIA2_RPC_DIR="/downloads"
# NFS mount from hub (must exist on apps).
export ARIA2_HOST_STAGING="/mnt/cluster/models/downloads"
