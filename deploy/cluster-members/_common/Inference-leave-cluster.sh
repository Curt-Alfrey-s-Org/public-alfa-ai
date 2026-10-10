#!/usr/bin/env bash
# Stop local 27B/35B rpc-server shard when a host leaves the pool.
#
# Usage (on the host being removed):
#   bash deploy/cluster-members/_common/inference-leave-cluster.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/inference-stop-local.sh"
echo "inference-leave-cluster: local rpc shard stopped ($(hostname -s))."
echo "  Edit grev27-pool-shards.env on apps, then on inference:"
echo "    bash deploy/cluster-members/inference-coordinator/write-grev27-pool-env.sh"
echo "    bash deploy/cluster-members/inference-coordinator/deploy-grev27-pool-coordinator.sh"
