#!/usr/bin/env bash
# DEPRECATED (Jul 2026): edge proxy hub moved to inference.
# Use deploy/cluster-members/_common/start-edge-api.sh on inference instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "WARN: start-edge-api.sh is deprecated — edge hub is inference; calling start-edge-api.sh" >&2
exec bash "$SCRIPT_DIR/start-edge-api.sh"
