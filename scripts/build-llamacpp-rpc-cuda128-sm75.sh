#!/usr/bin/env bash
# DEPRECATED: build on hub hub only (hub-hub-first).
#
#   sudo bash scripts/build-llamacpp-rpc-cuda128-on-hub.sh
#
# Workers load via:
#   bash deploy/cluster-members/_common/load-llamacpp-rpc-from-hub.sh
set -euo pipefail

echo "ERROR: build alfa-llamacpp-rpc:cuda128 on hub only (hub builder + NAS)." >&2
echo "  From hub: sudo bash scripts/build-llamacpp-rpc-cuda128-on-hub.sh" >&2
echo "  Workers:   bash deploy/cluster-members/_common/load-llamacpp-rpc-from-hub.sh" >&2
exit 1
