#!/usr/bin/env bash
# Permanent fast path: RAG embed + rerank trees on local disk (not NFS).
#
# Called by deploy-rag-cpu.sh on inference before compose up. Hub NFS is the seed;
# steady-state reads are from $HOME/alfa-ai-cache/rag (or ALFA_RAG_CACHE).
#
# Policy (docs/HUB_ARTIFACTS.md):
#   1. Prefer existing local trees
#   2. Else copy once from /mnt/cluster (NFS) into local cache
#   3. Never download from the public internet
#
# Usage (from deploy script -- stdout is ONLY export lines):
#   eval "$(bash .../ensure-rag-models-local-cache.sh | grep -E '^export ')"
# Status/progress must go to stderr so eval never sees "== ..." banners.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_ROOT="${ALFA_RAG_CACHE:-${HOME}/alfa-ai-cache/rag}"
RERANK_LOCAL="${LOCAL_ROOT}/reranker"
EMBED_LOCAL="${LOCAL_ROOT}/embed-qwen3-4b"

HUB_RERANK="${RERANK_HUB:-/mnt/cluster/models/downloads/reranker}"
HUB_EMBED="${EMBED_HUB:-/mnt/cluster/models/ollama/embed-qwen3-4b}"

dir_nonempty() {
  local d="$1"
  [[ -d "$d" ]] && [[ -n "$(ls -A "$d" 2>/dev/null || true)" ]]
}

need_hub=0
if ! dir_nonempty "$RERANK_LOCAL"; then
  need_hub=1
fi
if ! dir_nonempty "$EMBED_LOCAL"; then
  need_hub=1
fi

if [[ "$need_hub" -eq 1 ]]; then
  # preflight prints "== ..." on stdout -- keep that off the eval stream
  bash "$SCRIPT_DIR/preflight-nfs-hub.sh" >&2
fi

promote_tree() {
  local hub="$1"
  local dest="$2"
  local label="$3"
  if dir_nonempty "$dest"; then
    echo "  ensure-rag-models-local-cache: hit $dest" >&2
    return 0
  fi
  if [[ ! -d "$hub" ]]; then
    echo "ERROR: hub $label missing: $hub" >&2
    echo "  Seed on hub then remount NFS; see docs/HUB_ARTIFACTS.md" >&2
    return 1
  fi
  mkdir -p "$dest"
  echo "  ensure-rag-models-local-cache: promoting $hub -> $dest (once)" >&2
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$hub/" "$dest/" >&2
  else
    cp -a "$hub/." "$dest/"
  fi
}

promote_tree "$HUB_RERANK" "$RERANK_LOCAL" "reranker"
promote_tree "$HUB_EMBED" "$EMBED_LOCAL" "embed-qwen3-4b"

# Shell assignments for eval by caller (stdout only).
printf 'export RERANK_MODELS_DIR=%q\n' "$RERANK_LOCAL"
printf 'export OLLAMA_EMBED_MODELS_DIR=%q\n' "$EMBED_LOCAL"
