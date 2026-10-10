#!/usr/bin/env bash
# One-shot aria2 setup for Ubuntu apps host apps.
set -euo pipefail

REPO='/home/operator/alfa-ai'
STACK_DIR="$REPO/deploy/aria2"
ENV_FILE="$STACK_DIR/.env"
DOWNLOADS='/home/operator/alfa-ai/data/aria2-downloads'
SMOKE="$REPO/deploy/cluster-members/apps/aria2-smoke.sh"

# The RPC key is never stored in the repo: export it before running this script.
: "${ARIA2_RPC_KEY:?export ARIA2_RPC_KEY first (same value as the hub aria2 stack; new rpc key: openssl rand -hex 24). See deploy/aria2/README.md}"
export ARIA2_RPC_KEY

mkdir -p "$DOWNLOADS"
( umask 077; printf 'ARIA2_RPC_KEY=%s\n' "$ARIA2_RPC_KEY" > "$ENV_FILE" )
cat >> "$ENV_FILE" <<'EOF'
ARIA2_DOWNLOADS_HOST_PATH=/home/operator/alfa-ai/data/aria2-downloads
TZ=UTC
PUID=1000
PGID=1000
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
echo 'Bootstrap complete for apps.'
