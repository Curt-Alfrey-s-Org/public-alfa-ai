#!/usr/bin/env bash
# hub hub — post-startup status + optional SCP to inference hub.
#   SCP_TO_BUILD_HOST=1 bash deploy/cluster-members/hub/run-post-startup-status-with-log.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOST_PROFILE=hub-111
exec bash "$SCRIPT_DIR/../_common/run-post-startup-status-with-log.sh" "$@"
