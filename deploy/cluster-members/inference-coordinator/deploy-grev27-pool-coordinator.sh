#!/usr/bin/env bash
# SUPERSEDED (Jul 2026): 27B CPU coordinator moved to hub (:31360).
# inference runs rpc-server shards only (:31356/:31357).
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/deploy-grev27-pool-coordinator.sh
set -euo pipefail

echo "ERROR: 27B coordinator runs on hub CPU :31360, not inference." >&2
echo "  On hub: sudo bash deploy/cluster-members/hub/deploy-grev27-pool-coordinator.sh" >&2
echo "  Or full cluster: operator-cluster-111.sh start-pool (shard + coordinator)." >&2
echo "  Stop stale inference coordinator: HOST_LABEL=148 bash deploy/cluster-members/_common/inference-stop-local.sh" >&2
exit 1