#!/usr/bin/env bash
# Remove all local alfa-llamacpp-rpc Docker images and stopped RPC containers.
# Workers must reload ONLY from hub hub tarball after this (never host-to-host).
#
# Usage:
#   bash deploy/cluster-members/_common/purge-llamacpp-rpc-images.sh
#   HOST_LABEL=148 bash deploy/cluster-members/_common/purge-llamacpp-rpc-images.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_LABEL="${HOST_LABEL:-$(hostname -s)}"

echo "== purge-llamacpp-rpc: $HOST_LABEL =="

if [[ -f "$SCRIPT_DIR/inference-stop-local.sh" ]]; then
  bash "$SCRIPT_DIR/inference-stop-local.sh"
fi

mapfile -t ids < <(docker images --format '{{.ID}} {{.Repository}}' 2>/dev/null \
  | awk '$2 ~ /alfa-llamacpp-rpc/ { print $1 }' | sort -u || true)

if [[ ${#ids[@]} -eq 0 ]]; then
  echo "  no alfa-llamacpp-rpc images to remove"
else
  for img_id in "${ids[@]}"; do
    echo "  docker rmi -f $img_id"
    docker rmi -f "$img_id" 2>/dev/null || true
  done
fi

docker image prune -f >/dev/null 2>&1 || true
echo "purge-llamacpp-rpc OK on $HOST_LABEL"
