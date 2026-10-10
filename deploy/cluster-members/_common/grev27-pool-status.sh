#!/usr/bin/env bash
# Print 27B RPC pool shard registry + TCP reachability from this host.
#
# Usage:
#   bash deploy/cluster-members/_common/grev27-pool-status.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=grev27-pool-shards-lib.sh
source "$SCRIPT_DIR/grev27-pool-shards-lib.sh"

grev27_print_shard_registry
echo
echo "TCP (from $(hostname -s)):"
for hp in "${GREV27_SHARD_HOST_PORTS[@]}"; do
  host="${hp%%:*}"
  port="${hp##*:}"
  if nc -z -w 3 "$host" "$port" 2>/dev/null; then
    echo "  OK   $hp"
  else
    echo "  DOWN $hp"
  fi
done

coord="${GREV27_COORDINATOR_URL:-http://hub}"
echo
echo "Coordinator $coord/health:"
if curl -fsS --max-time 10 "${coord%/}/health" 2>/dev/null; then
  echo
else
  echo "  (unreachable or timeout)"
fi
