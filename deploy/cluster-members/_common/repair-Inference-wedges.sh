#!/usr/bin/env bash
# Repair RPC wedge on inference GPU shards (containers Up, TCP ports closed).
# Run after coordinator /health is 200 and optional settle sleep.
#
# Usage:
#   HOST_LABEL=93  bash repair-inference-wedges.sh    # local orchestrator shard only
#   HOST_LABEL=148 bash repair-inference-wedges.sh   # inference dual shards
#   HOST_LABEL=111 bash repair-inference-wedges.sh   # hub :31353 (on hub or via SSH)
#   HOST_LABEL=hub bash repair-inference-wedges.sh   # all shards from inference hub vantage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
LABEL="${HOST_LABEL:-$(hostname -s)}"
SETTLE="${inference_SHARD_SETTLE_SEC:-45}"

probe_tcp() {
  local host="$1" port="$2"
  nc -z -w 3 "$host" "$port" 2>/dev/null
}

repair_148() {
  if probe_tcp 127.0.0.1 31356 && probe_tcp 127.0.0.1 31357; then
    echo "  OK inference :31356 and :31357 listening"
    return 0
  fi
  echo "  WEDGE inference shards - redeploy"
  bash "$REPO_DIR/deploy/cluster-members/inference-coordinator/deploy-grev27-pool-shard.sh"
}

repair_111() {
  if probe_tcp 127.0.0.1 31353 || probe_tcp hub 31353; then
    echo "  OK hub :31353 listening"
    return 0
  fi
  echo "  WEDGE hub :31353 - redeploy shard"
  sudo bash "$REPO_DIR/deploy/cluster-members/hub/deploy-grev27-pool-shard.sh"
}

repair_all_from_hub() {
  local ip111="${IP_111:-hub}"
  local repo111="${REPO_111:-/mnt/hub/alfa-ai/repo/alfa-ai}"
  echo "== repair-inference-wedges from hub (settle ${SETTLE}s) =="
  if [[ "$SETTLE" -gt 0 ]]; then
    sleep "$SETTLE"
  fi
  if ! probe_tcp orchestrator 31350; then
    echo "  WARN orchestrator :31350 down from hub (redeploy from orchestrator orchestrator)"
  else
    echo "  OK orchestrator :31350 from hub"
  fi
  if ! probe_tcp 127.0.0.1 31356 || ! probe_tcp 127.0.0.1 31357; then
    repair_148
  fi
  if ! probe_tcp "$ip111" 31353; then
    echo "  WEDGE hub :31353 from hub - SSH redeploy"
    ssh -o BatchMode=yes -o ConnectTimeout=15 -i ~/.ssh/id_ed25519_cluster \
      "operator@${ip111}" "sudo bash ${repo111}/deploy/cluster-members/hub/deploy-grev27-pool-shard.sh"
  else
    echo "  OK hub :31353 from hub"
  fi
}

echo "== repair-inference-wedges: $LABEL =="
case "$LABEL" in
  148|ai-148) repair_148 ;;
  111|hub-111) repair_111 ;;
  hub|148-hub) repair_all_from_hub ;;
  *)
    echo "ERROR: HOST_LABEL=$LABEL (use 93|148|111|hub)" >&2
    exit 1
    ;;
esac
echo "repair-inference-wedges done on $LABEL"