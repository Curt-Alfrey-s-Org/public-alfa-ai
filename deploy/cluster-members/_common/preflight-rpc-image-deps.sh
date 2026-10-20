#!/usr/bin/env bash
# Read-only RPC docker image dependency check (no docker load, no hub promote).
#
# Exit 0 when the host can satisfy deploy-llamacpp-rpc / load-llamacpp-rpc-from-hub:
#   - docker image already present (unless --force-hub-load), OR
#   - hub/local tarball exists on a documented path.
#
# Usage:
#   bash deploy/cluster-members/_common/preflight-rpc-image-deps.sh
#   bash deploy/cluster-members/_common/preflight-rpc-image-deps.sh --force-hub-load
#   bash deploy/cluster-members/_common/preflight-rpc-image-deps.sh --pascal
#
# Official docker inspect: https://docs.docker.com/reference/cli/docker/image/inspect/
set -euo pipefail

FORCE=0
PASCAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-hub-load) FORCE=1; shift ;;
    --pascal) PASCAL=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--force-hub-load] [--pascal]" >&2
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$PASCAL" -eq 1 ]]; then
  IMAGE='alfa-llamacpp-rpc:cuda128-pascal'
  TARBALL='alfa-llamacpp-rpc-cuda128-pascal-b10355.tar.gz'
else
  IMAGE='alfa-llamacpp-rpc:cuda128'
  TARBALL="${ALFA_RPC_TARBALL:-alfa-llamacpp-rpc-cuda128-b10355.tar.gz}"
fi

if [[ "$FORCE" -ne 1 ]]; then
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "OK: $IMAGE already loaded on $(hostname -s) (skip tarball preflight)"
    exit 0
  fi
fi

HUB_SOURCES=(
  /mnt/hub/alfa-ai/docker-images
  /mnt/cluster/docker-images
  /mnt/hub/alfa-ai/temp/cluster_members/_common/docker-images
  /mnt/hub/alfa-ai/smb-scratch/cluster_members/_common/docker-images
)

LOCAL_TARGETS=()
if [[ -n "${ALFA_RPC_IMAGE_CACHE:-}" ]]; then
  LOCAL_TARGETS+=("${ALFA_RPC_IMAGE_CACHE}")
fi
LOCAL_TARGETS+=(
  /mnt/nvme/Alfa-AI/docker-images
  /mnt/ssd/Alfa-AI/docker-images
  "${HOME}/alfa-ai-cache/docker-images"
)

checked=()
for root in "${LOCAL_TARGETS[@]}" "${HUB_SOURCES[@]}"; do
  [[ -n "$root" ]] || continue
  case " ${checked[*]} " in
    *" $root "*) continue ;;
  esac
  checked+=("$root")
  if [[ -f "$root/$TARBALL" ]]; then
    echo "OK: $TARBALL on $(hostname -s) at $root"
    exit 0
  fi
done

echo "ERROR: $(hostname -s) missing $TARBALL (image=$IMAGE force_hub=$FORCE)" >&2
echo "  Checked: ${checked[*]}" >&2
echo "  Build on hub: sudo bash scripts/build-llamacpp-rpc-cuda128-on-hub.sh" >&2
if [[ "$PASCAL" -eq 1 ]]; then
  echo "  Pascal: sudo bash scripts/build-llamacpp-rpc-cuda128-pascal-on-hub.sh" >&2
fi
echo "  Or copy into ~/alfa-ai-cache/docker-images/ then retry start." >&2
exit 1
