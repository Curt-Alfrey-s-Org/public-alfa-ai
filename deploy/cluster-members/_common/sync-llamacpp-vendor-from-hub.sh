#!/usr/bin/env bash
# Copy hub-staged llama.cpp.tar.gz into deploy/llamacpp-rpc/vendor/ (Linux / hub).
# Non-fatal if missing: Docker build falls back to git clone.
#
# Usage:
#   bash deploy/cluster-members/_common/sync-llamacpp-vendor-from-hub.sh /path/to/alfa-ai
# Or:   ALFA_AI_REPO=/path/to/alfa-ai bash ...
set -euo pipefail

REPO_DIR="${1:-${ALFA_AI_REPO:-}}"
if [[ -z "$REPO_DIR" ]] || [[ ! -d "$REPO_DIR" ]]; then
  echo "Usage: $0 /path/to/alfa-ai-repo" >&2
  echo "   or: ALFA_AI_REPO=/path/to/alfa-ai $0" >&2
  exit 2
fi

HUB_TAR="${HUB_LLAMACPP_VENDOR_TAR:-}"
if [[ -z "$HUB_TAR" ]]; then
  for cand in \
    "/mnt/hub/alfa-ai/smb-scratch/cluster_members/_common/source-tarballs/llama.cpp.tar.gz" \
    "/mnt/cluster/smb-scratch/cluster_members/_common/source-tarballs/llama.cpp.tar.gz"; do
    if [[ -f "$cand" ]]; then
      HUB_TAR="$cand"
      break
    fi
  done
fi

VENDOR="$REPO_DIR/deploy/llamacpp-rpc/vendor"
DEST="$VENDOR/llama.cpp.tar.gz"
mkdir -p "$VENDOR"

# Warm path: local vendor already present and inference uses hub Docker image --
# do not re-copy from hub on every start.
if [[ -f "$DEST" ]] && [[ "${FORCE_VENDOR_SYNC:-}" != "1" ]]; then
  if [[ -n "$HUB_TAR" ]] && [[ -f "$HUB_TAR" ]]; then
    hub_sz="$(stat -c '%s' "$HUB_TAR" 2>/dev/null || stat -f '%z' "$HUB_TAR" 2>/dev/null || echo 0)"
    dest_sz="$(stat -c '%s' "$DEST" 2>/dev/null || stat -f '%z' "$DEST" 2>/dev/null || echo 0)"
    if [[ "$hub_sz" != "0" && "$hub_sz" == "$dest_sz" ]]; then
      echo "Skip hub vendor sync - local size matches: $DEST"
      exit 0
    fi
  else
    echo "Skip hub vendor sync - using local copy: $DEST"
    exit 0
  fi
fi

if [[ -z "$HUB_TAR" ]] || [[ ! -f "$HUB_TAR" ]]; then
  if [[ -f "$DEST" ]]; then
    echo "WARN: hub llama.cpp tarball missing; keeping local $DEST" >&2
    exit 0
  fi
  echo "WARN: hub llama.cpp tarball not found (build may use git clone). Pack on hub:" >&2
  echo "  sudo bash $REPO_DIR/scripts/pack-llamacpp-vendor-tarball-on-hub.sh" >&2
  exit 0
fi

cp -f "$HUB_TAR" "$DEST"
echo "Synced llama.cpp vendor tarball: $HUB_TAR -> $DEST"
