#!/usr/bin/env bash
# Pull the ALFa AI Ollama tier set into local Ollama (Linux / macOS).
#
# JUNE 2026 model upgrade (ROADMAP § "Operator-selected models (2026-06-17)"):
#   gaming-c gaming-worker-c   = qwen3.5:27b dense (quality default) + qwen3-embedding:4b
#   orchestrator hub = qwen3.6:35b-a3b MoE (speed)
#   gaming-b gaming-worker-b    = embed cold-standby (qwen3-embedding:4b); reranker is a
#                   Qwen3-Reranker-0.6B SIDECAR (TEI/Infinity/llama.cpp), NOT Ollama.
#   hub/apps/gaming-a = no chat LLM (delete Ollama there).
# Requires Ollama 0.30.x (Gated-DeltaNet arch) — verify the tag loads first.
#
# May 2026 audit HUB-001 — hub-first policy:
#   Before calling `ollama pull`, probe the hub hub for the model manifest and
#   merge-copy manifests/ + blobs/ into ~/.ollama/models (same layout as local Ollama).
#   Falls back to `ollama pull` only when the hub is missing the tag or unreachable.
#
# Environment (optional):
#   ALFA_OLLAMA_HUB_MODELS   Explicit path to hub directory that mirrors ~/.ollama/models
#                            (must contain manifests/ and blobs/). Highest precedence.
#   ALFA_OLLAMA_HUB_ROOT     Directory under which models live (we try .../models first).
#   ALFA_OLLAMA_SKIP_HUB     If non-empty, skip hub probe/sync (force public pull only).
#
# Default hub candidates (first readable directory with manifests/registry... wins):
#   $ALFA_OLLAMA_HUB_MODELS, $ALFA_OLLAMA_HUB_ROOT/models, /mnt/cluster/ollama/models,
#   /mnt/hub/alfa-ai/ollama/models, /mnt/hub/alfa-ai/models/ollama
#
# Hub seeding (download TO hub): use scripts/hub_hub_models.sh on hub —
# DO NOT curl /api/pull from another host. See docs/HTTP_DOWNLOADS.md.
#
# Fleet sync (read FROM hub on workers): this script merges hub manifests+blobs,
# then ollama pull only for missing tags.
# (audit OLLAMA-002 / backlog #24). Architecture: docs/DISTRIBUTED_AI.md; tiers: docs/QWEN3_MIGRATION.md.
#
# Roles:
#   quality  — gaming-c gaming-worker-c. Primary embed only (qwen3.5:27b removed Phase G).
#              chat/agent/code route to GPU 35B on orchestrator/inference via LiteLLM.
#   speed    — orchestrator hub. CPU chat speed host (qwen3.6:35b-a3b MoE ~22 GB, ~3B active).
#              fast/inline/autocomplete route here; quality aliases fall back here.
#   embed    — gaming-c primary / gaming-b cold-standby. Pulls qwen3-embedding:4b only (~2.5 GB).
#   reranker — gaming-b gaming-worker-b. Embed standby only here; reranker model (Qwen3-Reranker-0.6B)
#              is a SIDECAR (TEI/Infinity/llama.cpp), NOT served via Ollama. No chat model.
#   all      — quality (convenience; same full set for gaming-c).
#   brain    — DEPRECATED (hub no longer runs chat models). Prints warning, pulls nothing.
#   fleet    — DEPRECATED (30B MoE fleet retired). Prints warning, pulls nothing.
#
# Usage:
#   ./pull-models.sh quality          # gaming-c gaming-worker-c (qwen3.5:27b + embed)
#   ./pull-models.sh speed            # orchestrator (qwen3.6:35b-a3b MoE)
#   ./pull-models.sh embed            # gaming-c or gaming-b (embed only)
#   ./pull-models.sh reranker         # gaming-b gaming-worker-b (embed standby; reranker = sidecar)
#   ./pull-models.sh all              # same as quality
#   ./pull-models.sh brain            # DEPRECATED — warns, no-op
set -euo pipefail

role="${1:-quality}"

quality_tags=(qwen3-embedding:4b)
speed_tags=(qwen3.6:35b-a3b)
embed_tags=(qwen3-embedding:4b)
reranker_tags=(qwen3-embedding:4b)

case "$role" in
  quality)   tags=("${quality_tags[@]}") ;;
  speed)     tags=("${speed_tags[@]}") ;;
  embed)     tags=("${embed_tags[@]}") ;;
  reranker)  tags=("${reranker_tags[@]}") ;;
  all)       tags=("${quality_tags[@]}") ;;
  brain|agent|fleet|inline)
    echo "WARNING: Role '$role' is DEPRECATED." >&2
    echo "  hub/apps/gaming-a: no chat LLM. gaming-c: use 'quality'. orchestrator: use 'speed'. gaming-b: use 'reranker'." >&2
    echo "  No models will be pulled. See docs/ROADMAP.md § Operator-selected models (2026-06-17)." >&2
    exit 0
    ;;
  *)
    echo "ERROR: Unknown role '$role'. Use quality | speed | embed | reranker | all." >&2
    exit 2
    ;;
esac

if ! command -v ollama >/dev/null 2>&1; then
  echo "ERROR: ollama not found on PATH. Install from https://ollama.com/download first." >&2
  exit 1
fi

# Relative path under hub models dir for Ollama library manifest (blob refs live under blobs/).
_manifest_rel_for_tag() {
  local tag="$1"
  local lib="manifests/registry.ollama.ai/library"
  if [[ "$tag" == *:* ]]; then
    printf '%s/%s/%s\n' "$lib" "${tag%%:*}" "${tag#*:}"
  else
    printf '%s/%s/latest\n' "$lib" "$tag"
  fi
}

# First argument must be a directory whose resolved path contains the manifest file for tag.
_hub_has_manifest() {
  local hub_models="$1"
  local tag="$2"
  local rel
  rel="$(_manifest_rel_for_tag "$tag")"
  [[ -f "$hub_models/$rel" ]]
}

# Pick hub models directory (contains manifests/ + blobs/).
_resolve_hub_models_dir() {
  if [[ -n "${ALFA_OLLAMA_SKIP_HUB:-}" ]]; then
    echo ""
    return 0
  fi
  local cands=()
  [[ -n "${ALFA_OLLAMA_HUB_MODELS:-}" ]] && cands+=("$ALFA_OLLAMA_HUB_MODELS")
  if [[ -n "${ALFA_OLLAMA_HUB_ROOT:-}" ]]; then
    cands+=("${ALFA_OLLAMA_HUB_ROOT%/}/models")
    cands+=("${ALFA_OLLAMA_HUB_ROOT%/}")
  fi
  cands+=(
    "/mnt/cluster/ollama/models"
    "/mnt/cluster/ollama"
    "/mnt/hub/alfa-ai/ollama/models"
    "/mnt/hub/alfa-ai/models/ollama"
  )
  local d
  for d in "${cands[@]}"; do
    [[ -z "$d" ]] && continue
    [[ -d "$d/manifests/registry.ollama.ai/library" ]] || continue
    printf '%s\n' "$d"
    return 0
  done
  echo ""
}

_sync_hub_models_merge() {
  local hub_models="$1"
  local dest="${OLLAMA_MODELS:-$HOME/.ollama/models}"
  mkdir -p "$dest"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${hub_models}/" "${dest}/"
  else
    cp -a "${hub_models}/." "${dest}/"
  fi
}

_refresh_present_list() {
  ollama list 2>/dev/null | awk 'NR>1 {print $1}' || true
}

echo "== Ollama pull ($role) — hub-first (audit HUB-001) =="
hub_models="$(_resolve_hub_models_dir)"
if [[ -n "$hub_models" ]]; then
  echo "  hub models dir: $hub_models"
else
  echo "  hub: not resolved (set ALFA_OLLAMA_HUB_MODELS or mount NFS/SMB); will use ollama pull only"
fi

present="$(_refresh_present_list)"

need_merge=0
if [[ -n "$hub_models" ]]; then
  for tag in "${tags[@]}"; do
    if printf '%s\n' "$present" | grep -Fxq "$tag"; then
      continue
    fi
    if _hub_has_manifest "$hub_models" "$tag"; then
      need_merge=1
      break
    fi
  done
  if [[ "$need_merge" -eq 1 ]]; then
    echo "  [hub] merging manifests+blobs from hub (one-shot, audit HUB-001)..."
    _sync_hub_models_merge "$hub_models" || echo "  [hub] WARN: merge failed — will try ollama pull per tag" >&2
    present="$(_refresh_present_list)"
  fi
fi

for tag in "${tags[@]}"; do
  if printf '%s\n' "$present" | grep -Fxq "$tag"; then
    echo "  [skip] $tag already present"
    continue
  fi

  if [[ -n "$hub_models" ]] && ! _hub_has_manifest "$hub_models" "$tag"; then
    echo "  [hub] no manifest for $tag — using ollama pull"
  fi

  echo "  [pull] $tag"
  if ! ollama pull "$tag"; then
    echo "  WARN: failed to pull $tag (retry manually: ollama pull $tag)" >&2
  fi
  present="$(_refresh_present_list)"
done

echo ""
echo "Done. Current Ollama models:"
ollama list
