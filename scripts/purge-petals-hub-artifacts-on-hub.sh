#!/usr/bin/env bash
# Remove Petals/Hivemind artifacts from hub hub (hub).
# Keeps llama.cpp RPC, Ollama, GGUF, bot/victron wheels, and non-Petals docker tarballs.
#
# Usage (on hub, repo checkout):
#   cd /mnt/hub/alfa-ai/repo/alfa-ai
#   sudo bash scripts/purge-petals-hub-artifacts-on-111.sh          # dry-run (default)
#   sudo bash scripts/purge-petals-hub-artifacts-on-111.sh --apply  # delete
#
# Optional: SCP_TO_BUILD_HOST=1 bash deploy/cluster-members/hub/run-purge-petals-hub-artifacts.sh
#   (logs to inference via run wrapper; see docs/HUB_ARTIFACTS.md)
#
# Docs: docs/HUB_ARTIFACTS.md (retired Petals inventory)
set -euo pipefail

APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    -h|--help)
      sed -n '1,14p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

HUB_ROOT="${HUB_ROOT:-/mnt/hub/alfa-ai}"
CLUSTER_ROOT="${CLUSTER_ROOT:-/mnt/cluster}"

log() { printf '%s\n' "$*"; }
action_rm() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    log "DELETE: $path"
    rm -rf "$path"
  else
    log "WOULD DELETE: $path"
  fi
}

action_rmi() {
  local ref="$1"
  if [[ "$APPLY" -eq 1 ]]; then
    log "DOCKER RMI: $ref"
    docker rmi -f "$ref" 2>/dev/null || true
  else
    log "WOULD DOCKER RMI: $ref"
  fi
}

log "=== Petals hub purge (hub) mode=$([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN) ==="
log "HUB_ROOT=$HUB_ROOT CLUSTER_ROOT=$CLUSTER_ROOT"
log ""

# --- Docker image tarballs (Petals ml-base / worker / gateway) ----------------
TARBALL_GLOBS=(
  "alfa-ai-petals-gateway*.tar.gz"
  "alfa-petals-*.tar.gz"
  "petals-worker*.tar.gz"
  "petals-worker-gpu*.tar.gz"
)

for root in "$HUB_ROOT/docker-images" "$CLUSTER_ROOT/docker-images"; do
  [[ -d "$root" ]] || continue
  for g in "${TARBALL_GLOBS[@]}"; do
    while IFS= read -r -d '' f; do
      action_rm "$f"
    done < <(find "$root" -maxdepth 1 -type f -name "$g" -print0 2>/dev/null || true)
  done
done

# --- ml-base wheel trees (Petals Docker builds only; bots/victron kept) -------
for sub in cpu cuda cuda-blackwell; do
  for root in "$HUB_ROOT/wheels" "$CLUSTER_ROOT/wheels"; do
    action_rm "${root}/${sub}"
    action_rm "${root}/${sub}/.pip-cache"
    action_rm "${root}/${sub}/.tmp"
  done
done

# --- Petals DHT / identity / bootstrap --------------------------------------
for root in "$HUB_ROOT/petals" "$CLUSTER_ROOT/petals"; do
  action_rm "$root"
done

# --- HuggingFace cache: Llama 3.3 70B (Petals tier 3a) ----------------------
HF_HUB="${HUB_ROOT}/models/huggingface/hub"
if [[ -d "$HF_HUB" ]]; then
  while IFS= read -r -d '' d; do
    action_rm "$d"
  done < <(find "$HF_HUB" -maxdepth 1 -type d -name 'models--meta-llama--Llama-3.3-70B*' -print0 2>/dev/null || true)
fi
for root in "$HUB_ROOT/models/huggingface" "$CLUSTER_ROOT/models/huggingface"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' d; do
    case "$(basename "$d")" in
      models--meta-llama--Llama-3.3-70B*) action_rm "$d" ;;
    esac
  done < <(find "$root" -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null || true)
done

# --- Local Docker engine images (if daemon reachable) -------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    case "$ref" in
      *petals*|*Petals*) action_rmi "$ref" ;;
    esac
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Ei 'petals' || true)
fi

log ""
if [[ "$APPLY" -eq 1 ]]; then
  log "Done. Kept: wheels/bots, wheels/victron, llama-cpp GGUF, Ollama blobs, alfa-llamacpp-rpc tarballs."
else
  log "Dry-run complete. Re-run with --apply to delete."
fi
