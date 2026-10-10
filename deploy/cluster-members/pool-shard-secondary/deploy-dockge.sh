#!/usr/bin/env bash
set -euo pipefail
# Deploy Dockge agent + stack symlinks on gpu-248.
# Does not start or restart the inference rpc-server.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
bash "$REPO_ROOT/deploy/cluster-members/_common/install-dockge-agent-linux.sh" \
	deploy/cluster-members/pool-shard-secondary stackssecondary.yml orchestrator
