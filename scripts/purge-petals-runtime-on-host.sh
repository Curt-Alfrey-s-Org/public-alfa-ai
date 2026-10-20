#!/usr/bin/env bash
# Remove leftover Petals/Hivemind containers, images, and local env on this host.
# Safe on RPC-only hosts: no-ops when nothing Petals-related is present.
#
# Usage:
#   bash scripts/purge-petals-runtime-on-host.sh          # dry-run
#   bash scripts/purge-petals-runtime-on-host.sh --apply
#
# Windows (WSL Docker):
#   wsl -d Ubuntu bash -lc 'cd /mnt/c/Users/operator/alfa-ai && bash scripts/purge-petals-runtime-on-host.sh --apply'
#
# Docs: docs/HUB_ARTIFACTS.md (hub purge is separate: purge-petals-hub-artifacts-on-111.sh)
set -euo pipefail

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    -h|--help)
      sed -n '1,16p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    echo "ERROR: docker not reachable (start Docker / WSL engine first)" >&2
    exit 1
  fi
fi

log() { printf '%s\n' "$*"; }

NAMES=(
  petals-worker
  petals-worker-a
  petals-worker-b
  petals-worker-cpu
  alfa-ai-petals-gateway
  alfa-ai-petals-worker
)

log "=== Petals runtime purge mode=$([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN) ==="

for name in "${NAMES[@]}"; do
  if "${DOCKER[@]}" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
    if [[ "$APPLY" -eq 1 ]]; then
      log "RM CONTAINER: $name"
      "${DOCKER[@]}" rm -f "$name" >/dev/null || true
    else
      log "WOULD RM CONTAINER: $name"
    fi
  fi
done

while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  if [[ "$APPLY" -eq 1 ]]; then
    log "RMI: $ref"
    "${DOCKER[@]}" rmi -f "$ref" >/dev/null 2>&1 || true
  else
    log "WOULD RMI: $ref"
  fi
done < <("${DOCKER[@]}" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Ei 'petals' || true)

VOLS=(
  petals-hf-cache
  petals-identity
  petals-bootstrap
  petals-gateway-hf-cache
  petals-hf-cache-cpu
)
for v in "${VOLS[@]}"; do
  if "${DOCKER[@]}" volume inspect "$v" >/dev/null 2>&1; then
    if [[ "$APPLY" -eq 1 ]]; then
      log "RM VOLUME: $v"
      "${DOCKER[@]}" volume rm "$v" >/dev/null 2>&1 || true
    else
      log "WOULD RM VOLUME: $v"
    fi
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
for f in \
  "${REPO_ROOT}/deploy/petals/.env.worker" \
  "${REPO_ROOT}/deploy/.env.gateway" \
  "${REPO_ROOT}/deploy/petals/dockge.local.env"
do
  if [[ -f "$f" ]]; then
    if [[ "$APPLY" -eq 1 ]]; then
      log "RM FILE: $f"
      rm -f "$f"
    else
      log "WOULD RM FILE: $f"
    fi
  fi
done

log ""
if [[ "$APPLY" -eq 1 ]]; then
  log "Done. Hub SMB petals-wheels bots/victron and llama.cpp RPC assets are untouched."
else
  log "Dry-run complete. Re-run with --apply to delete."
fi
