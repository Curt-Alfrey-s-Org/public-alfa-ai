#!/usr/bin/env bash
# SUPERSEDED: coordinator .env.rpc is generated on hub from inference-shards.env.
#   bash deploy/cluster-members/hub/write-grev27-pool-env.sh
set -euo pipefail
echo "ERROR: run write-grev27-pool-env on hub (see inference-shards.env)." >&2
exit 1