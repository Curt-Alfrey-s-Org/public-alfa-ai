#!/usr/bin/env bash
# hub Scale — hub (hub). Paths match deploy.sh on this host.
#
# Usage (interactive shell on hub):
#   source /mnt/hub/alfa-ai/repo/alfa-ai/deploy/cluster-members/hub/aria2-env.sh
#
# Then (HF token only if needed for gated URLs):
#   sudo -E bash /mnt/hub/alfa-ai/repo/alfa-ai/scripts/hub_hub_models.sh pull gguf
#   sudo -E bash /mnt/hub/alfa-ai/repo/alfa-ai/scripts/hub_hub_models.sh status
#
# Dockge: import stack from
#   /mnt/hub/alfa-ai/repo/alfa-ai/deploy/aria2/docker-compose.yml
# and set ARIA2_DOWNLOADS_HOST_PATH to the same value as below (default in compose).

export ALFA_AI_REPO="/mnt/hub/alfa-ai/repo/alfa-ai"
export HUB_ROOT="/mnt/hub/alfa-ai"
export ARIA2_DOWNLOADS_HOST_PATH="/mnt/hub/alfa-ai/models/downloads"
export ARIA2_RPC_URL="http://127.0.0.1:6800/jsonrpc"
# ARIA2_RPC_KEY is not stored in the repo: export it yourself (same value as the
# hub aria2 stack) before or after sourcing this file.
export ARIA2_RPC_KEY="${ARIA2_RPC_KEY:-}"
if [[ -z "$ARIA2_RPC_KEY" ]]; then
  echo 'WARN: ARIA2_RPC_KEY is not set; aria2 RPC calls will be rejected (see deploy/aria2/README.md).' >&2
fi
export ARIA2_RPC_DIR="/downloads"
export ARIA2_HOST_STAGING="/mnt/hub/alfa-ai/models/downloads"
