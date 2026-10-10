#!/usr/bin/env bash
# Register pool-switchd as a hub Init/Shutdown Script (Post Init).
#
# Usage (on hub as operator with admin for midclt if needed):
#   bash deploy/cluster-members/hub/install-pool-switchd-init.sh
#
# Manual start (debug):
#   ALFA_AI_REPO=/mnt/hub/alfa-ai/repo/alfa-ai python3 deploy/cluster-members/hub/pool-switchd.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
SWITCHD="$REPO_DIR/deploy/cluster-members/hub/pool-switchd.py"
LOG_DIR="${REPO_DIR}/logs/pool-switchd"
START_CMD="mkdir -p ${LOG_DIR} && ALFA_AI_REPO=${REPO_DIR} nohup python3 ${SWITCHD} >> ${LOG_DIR}/pool-switchd.log 2>&1 &"

if [[ ! -f "$SWITCHD" ]]; then
  echo "ERROR: missing $SWITCHD" >&2
  exit 1
fi

if ! grep -q '^ALFA_POOL_SWITCH_BEARER_TOKEN=.' "$REPO_DIR/deploy/.env" 2>/dev/null; then
  echo "WARN: set ALFA_POOL_SWITCH_BEARER_TOKEN in deploy/.env before relying on switchd" >&2
fi

echo "== pool-switchd init script =="
echo "Add this command in hub UI: System Settings -> Init/Shutdown Scripts"
echo "  Type: Command"
echo "  When: Post Init"
echo "  Enabled: Yes"
echo "  Command:"
echo "    ${START_CMD}"
echo ""
echo "Or append via midclt (requires admin):"
echo "  midclt call initshutdownscript.create '{\"type\":\"COMMAND\",\"when\":\"POSTINIT\",\"enabled\":true,\"comment\":\"alfa pool-switchd\",\"command\":\"${START_CMD}\"}'"
echo ""
echo "Verify:"
echo "  curl -fsS -H \"Authorization: Bearer \$(grep ALFA_POOL_SWITCH_BEARER_TOKEN deploy/.env | cut -d= -f2-)\" http://127.0.0.1:8421/health"
