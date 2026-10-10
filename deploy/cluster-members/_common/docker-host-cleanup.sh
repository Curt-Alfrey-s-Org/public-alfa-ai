#!/usr/bin/env bash
# Safe Docker host cleanup: builder cache + unused images/networks/containers.
# Never prunes named volumes. See docs/operations/DOCKER_HOST_CLEANUP.md
#
# Usage:
#   sudo bash docker-host-cleanup.sh
#   ALFA_DOCKER_CLEANUP_MODE=abort sudo bash docker-host-cleanup.sh
#
# Env:
#   ALFA_DOCKER_CLEANUP_MODE   scheduled|abort|manual (default scheduled)
#   ALFA_DOCKER_BUILDER_UNTIL  Go duration for builder prune (default by mode/host)
#   ALFA_DOCKER_SYSTEM_UNTIL   Go duration for system prune (default 168h)
#   ALFA_HUB_ROOT              default /mnt/hub/alfa-ai
#   ALFA_HUB_TMP_MAX_AGE_HOURS default 6
set -euo pipefail

MODE="${ALFA_DOCKER_CLEANUP_MODE:-scheduled}"
HUB_ROOT="${ALFA_HUB_ROOT:-/mnt/hub/alfa-ai}"
TMP_MAX_AGE_H="${ALFA_HUB_TMP_MAX_AGE_HOURS:-6}"
SYSTEM_UNTIL="${ALFA_DOCKER_SYSTEM_UNTIL:-168h}"

is_hub=0
if [[ -d "$HUB_ROOT/docker-images" ]] || [[ "$(hostname -s 2>/dev/null || true)" == *"hub"* ]] || [[ "$(hostname -s 2>/dev/null || true)" == *"hub"* ]]; then
  if [[ -d "$HUB_ROOT/docker-images" ]]; then
    is_hub=1
  fi
fi

case "$MODE" in
  abort)
    BUILDER_UNTIL="${ALFA_DOCKER_BUILDER_UNTIL:-1h}"
    ;;
  *)
    if [[ "$is_hub" -eq 1 ]]; then
      BUILDER_UNTIL="${ALFA_DOCKER_BUILDER_UNTIL:-72h}"
    else
      BUILDER_UNTIL="${ALFA_DOCKER_BUILDER_UNTIL:-168h}"
    fi
    ;;
esac

docker_wrap() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    sudo docker "$@"
  else
    echo "ERROR: Docker daemon not reachable" >&2
    exit 1
  fi
}

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[$ts] alfa docker-host-cleanup mode=$MODE builder_until=$BUILDER_UNTIL system_until=$SYSTEM_UNTIL hub=$is_hub"

if ! docker_wrap info >/dev/null 2>&1; then
  echo "ERROR: docker info failed" >&2
  exit 1
fi

echo "== docker builder prune -af --filter until=${BUILDER_UNTIL} =="
docker_wrap builder prune -af --filter "until=${BUILDER_UNTIL}" || true

echo "== docker system prune -af --filter until=${SYSTEM_UNTIL} (no volumes) =="
docker_wrap system prune -af --filter "until=${SYSTEM_UNTIL}" || true

if [[ "$is_hub" -eq 1 ]]; then
  img_dir="$HUB_ROOT/docker-images"
  if [[ -d "$img_dir" ]]; then
    echo "== remove hub docker-images/.*.tmp older than ${TMP_MAX_AGE_H}h =="
    # Partial docker save leftovers from interrupted publish.
    find "$img_dir" -maxdepth 1 -type f -name '.*.tmp' -mmin "+$((TMP_MAX_AGE_H * 60))" -print -delete 2>/dev/null || true
    if [[ "$MODE" == "abort" ]]; then
      find "$img_dir" -maxdepth 1 -type f -name '.*.tmp' -print -delete 2>/dev/null || true
    fi
  fi
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] alfa docker-host-cleanup DONE"
