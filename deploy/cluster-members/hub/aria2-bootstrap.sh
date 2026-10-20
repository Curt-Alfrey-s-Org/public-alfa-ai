#!/usr/bin/env bash
# One-shot aria2 setup for hub hub (hub).
set -euo pipefail

REPO='/mnt/hub/alfa-ai/repo/alfa-ai'
STACK_DIR="$REPO/deploy/aria2"
ENV_FILE="$STACK_DIR/.env"
DOWNLOADS='/mnt/hub/alfa-ai/models/downloads'
SMOKE="$REPO/deploy/cluster-members/hub/aria2-smoke.sh"

# The RPC key is never stored in the repo: export it before running this script.
: "${ARIA2_RPC_KEY:?export ARIA2_RPC_KEY first (same value as the hub aria2 stack; new rpc key: openssl rand -hex 24). See deploy/aria2/README.md}"
export ARIA2_RPC_KEY

mkdir -p "$DOWNLOADS"
( umask 077; printf 'ARIA2_RPC_KEY=%s\n' "$ARIA2_RPC_KEY" > "$ENV_FILE" )
cat >> "$ENV_FILE" <<'EOF'
ARIA2_DOWNLOADS_HOST_PATH=/mnt/hub/alfa-ai/models/downloads
TZ=UTC
PUID=0
PGID=0
EOF

cd "$STACK_DIR"
if docker compose ps >/dev/null 2>&1; then
  docker compose up -d
  docker compose ps
else
  sudo docker compose up -d
  sudo docker compose ps
fi

bash "$SMOKE"

echo
echo 'Bootstrap complete.'
echo 'Optional GGUF pull command:'
echo "  export HF_TOKEN='change-me'"
echo "  bash $REPO/deploy/cluster-members/hub/aria2-pull-gguf.sh"
