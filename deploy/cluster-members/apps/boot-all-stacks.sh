#!/usr/bin/env bash
# Boot all apps apps stacks (edge :8420 retired — use inference hub start-edge-api.sh).
#
# Usage:
#   bash deploy/cluster-members/apps/boot-all-stacks.sh
#   bash deploy/cluster-members/apps/boot-all-stacks.sh --only postgres,redis,alfa-ai-edge-api
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/deploy.sh" "$@"
