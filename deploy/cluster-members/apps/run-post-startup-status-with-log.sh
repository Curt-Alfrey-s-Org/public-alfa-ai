#!/usr/bin/env bash
# apps apps — post-startup status + optional SCP to inference hub (or local dir when run here).
#   bash deploy/cluster-members/apps/run-post-startup-status-with-log.sh
#   SCP_TO_BUILD_HOST=1 bash ...  # from another host only
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOST_PROFILE=apps-105
exec bash "$SCRIPT_DIR/../_common/run-post-startup-status-with-log.sh" "$@"
