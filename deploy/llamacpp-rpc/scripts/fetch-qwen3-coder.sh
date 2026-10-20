#!/usr/bin/env bash
# Fetch frontier-pool GGUF weights into the hub hub model store.
#
# *** MUST RUN ONLY ON hub (hub hub) ***
# Workers NEVER download multi-GB GGUFs from the internet. After staging here,
# all cluster hosts read from the hub over LAN (NFS/SMB). See:
#   docs/HUB_ARTIFACTS.md
#   docs/CLUSTER_SHARED_STORAGE.md
#   .cursor/plans/FOUR_HOST_FRONTIER_POOL.md Phase A
#
# Default hub destination (on hub):
#   /mnt/hub/alfa-ai/llama-cpp/models/
# NFS mount on workers:
#   /mnt/cluster/llama-cpp/models/
#
# Usage (on hub only):
#   cd /mnt/hub/alfa-ai/repo/alfa-ai/deploy/llamacpp-rpc
#   PROFILE=chat  ./scripts/fetch-qwen3-coder.sh
#   PROFILE=code  ./scripts/fetch-qwen3-coder.sh
#   PROFILE=agentic ./scripts/fetch-qwen3-coder.sh
#
# Override hub path:
#   MODELS_DIR=/mnt/hub/alfa-ai/llama-cpp/models PROFILE=chat ./scripts/fetch-qwen3-coder.sh
#
# After download, record exact relative path + sha256 in the SSoT plan (Phase A).
# Set MODEL_FILE in deploy/llamacpp-rpc/.env.rpc on orchestrator to that hub-relative path.
#
# Requires: bash; scripts/lib/http_fetch.sh (aria2-only — docs/HTTP_DOWNLOADS.md)
#   or official `hf` / huggingface-cli (https://huggingface.co/docs/huggingface_hub/en/guides/cli).
# Hub default: aria2 first (FETCH_GGUF_ARIA2_FIRST=1). No curl download fallback.
# After download, runs `hf cache verify` when `hf` is installed (official checksum check).
# REFRESH=1 removes the lead file before re-download.
# VERIFY_ONLY=1 skips download and only verifies.
# If HF returns 401, set HF_TOKEN (read token) and accept the license on the repo page.
set -euo pipefail

if [[ -z "${HF_TOKEN:-}" && -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
  export HF_TOKEN="$HUGGING_FACE_HUB_TOKEN"
fi

# ── Host guard: refuse to run on worker hosts ───────────────────────────────
HOST_IPS="$(hostname -I 2>/dev/null || true)"
if [[ -n "$HOST_IPS" ]] && [[ "$HOST_IPS" != *"hub"* ]] && [[ "${ALLOW_NON_HUB_FETCH:-0}" != "1" ]]; then
  echo "ERROR: This script MUST run on hub (hub hub) only." >&2
  echo "  Set ALLOW_NON_HUB_FETCH=1 to override (not for production workers)." >&2
  exit 1
fi

PROFILE="${PROFILE:-agentic}"
MODELS_DIR="${MODELS_DIR:-/mnt/hub/alfa-ai/llama-cpp/models}"
LEGACY_SINGLE="${LEGACY_SINGLE:-0}"
# Prefer aria2 (http_fetch) on the hub so multi-GB shards resume; no curl fallback.
FETCH_GGUF_ARIA2_FIRST="${FETCH_GGUF_ARIA2_FIRST:-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HTTP_FETCH_SH="$REPO_ROOT/scripts/lib/http_fetch.sh"
HF_GGUF_SH="$REPO_ROOT/deploy/cluster-members/_common/hf-gguf-hub.sh"
ARIA2_ENV_SH="$REPO_ROOT/deploy/cluster-members/hub/aria2-env.sh"
if [[ -f "$ARIA2_ENV_SH" ]]; then
  # shellcheck source=deploy/cluster-members/hub/aria2-env.sh
  source "$ARIA2_ENV_SH"
fi
if [[ -f "$HF_GGUF_SH" ]]; then
  # shellcheck source=deploy/cluster-members/_common/hf-gguf-hub.sh
  source "$HF_GGUF_SH"
fi

mkdir -p "$MODELS_DIR"

# ── Legacy 30B single-file pull (deprecated; tier 0/1/2 Ollama unchanged) ───
if [[ "$LEGACY_SINGLE" == "1" ]]; then
  REPO="${REPO:-unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF}"
  MODEL_FILE="${MODEL_FILE:-Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf}"
  dest="$MODELS_DIR/$MODEL_FILE"
  if [[ -f "$dest" ]]; then
    echo "Already present: $dest ($(du -h "$dest" | awk '{print $1}'))"
    exit 0
  fi
  echo "Fetching (legacy single GGUF) $REPO / $MODEL_FILE -> $dest"
  url="https://huggingface.co/${REPO}/resolve/main/${MODEL_FILE}?download=true"
  if [[ "${FETCH_GGUF_HF_CLI_FIRST:-0}" == "1" ]] && command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$REPO" "$MODEL_FILE" \
      --local-dir "$MODELS_DIR" \
      --local-dir-use-symlinks False
  elif [[ -f "$HTTP_FETCH_SH" ]]; then
    # shellcheck source=/dev/null
    source "$HTTP_FETCH_SH"
    if http_fetch_to "$url" "$dest"; then
      :
    elif command -v huggingface-cli >/dev/null 2>&1; then
      echo "http_fetch_to failed; trying huggingface-cli ..." >&2
      huggingface-cli download "$REPO" "$MODEL_FILE" \
        --local-dir "$MODELS_DIR" \
        --local-dir-use-symlinks False
    else
      exit 1
    fi
  elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$REPO" "$MODEL_FILE" \
      --local-dir "$MODELS_DIR" \
      --local-dir-use-symlinks False
  else
    echo "No huggingface-cli or $HTTP_FETCH_SH" >&2
    exit 1
  fi
  ls -lh "$dest"
  exit 0
fi

# ── Profile: chat (Qwen3.5-122B-A10B Q3_K_M) ───────────────────────────────
fetch_chat() {
  # unsloth/Qwen3.5-122B-A10B-GGUF Q3_K_M (3 shards, ~56 GB total). Apache 2.0 base model.
  REPO="${REPO:-unsloth/Qwen3.5-122B-A10B-GGUF}"
  MODEL_LEAD="${MODEL_LEAD:-Q3_K_M/Qwen3.5-122B-A10B-Q3_K_M-00001-of-00003.gguf}"
  HF_INCLUDE="${HF_INCLUDE:-Q3_K_M/*.gguf}"

  fetch_multi_or_single "$REPO" "$MODEL_LEAD" "$HF_INCLUDE"
}

# ── Profile: code (Qwen3.6-27B Q4_K_M — legacy rollback) ─────────────────────
fetch_code() {
  # unsloth/Qwen3.6-27B-GGUF Q4_K_M (~17 GB single file). Use code-ud for production.
  REPO="${REPO:-unsloth/Qwen3.6-27B-GGUF}"
  MODEL_LEAD="${MODEL_LEAD:-Qwen3.6-27B-Q4_K_M.gguf}"
  HF_INCLUDE="${HF_INCLUDE:-Qwen3.6-27B-Q4_K_M.gguf}"

  fetch_multi_or_single "$REPO" "$MODEL_LEAD" "$HF_INCLUDE"
}

# ── Profile: code-ud (Qwen3.6-27B UD-Q4_K_XL — multi-slot Q4 rollback) ───────
fetch_code_ud() {
  # Same repo as code (non-MTP). Keep on hub for PARALLEL=10 rollback.
  REPO="${REPO:-unsloth/Qwen3.6-27B-GGUF}"
  MODEL_LEAD="${MODEL_LEAD:-Qwen3.6-27B-UD-Q4_K_XL.gguf}"
  HF_INCLUDE="${HF_INCLUDE:-Qwen3.6-27B-UD-Q4_K_XL.gguf}"

  fetch_multi_or_single "$REPO" "$MODEL_LEAD" "$HF_INCLUDE"
}

# ── Profile: code-q8 (Qwen3.8-27B Q8_0 — inference production policy) ──────────
fetch_code_q8() {
  # ~29 GB; pairs with PARALLEL=5 / CTX_SIZE=262144 (52428/slot; 2 user + 3 auto).
  # Official artifact: https://huggingface.co/unsloth/Qwen3.8-27B-GGUF
  # Rollback: REPO=unsloth/Qwen3.6-27B-GGUF MODEL_LEAD=Qwen3.6-27B-Q8_0.gguf
  REPO="${REPO:-unsloth/Qwen3.8-27B-GGUF}"
  MODEL_LEAD="${MODEL_LEAD:-Qwen3.8-27B-Q8_0.gguf}"
  HF_INCLUDE="${HF_INCLUDE:-Qwen3.8-27B-Q8_0.gguf}"

  fetch_multi_or_single "$REPO" "$MODEL_LEAD" "$HF_INCLUDE"
}

require_mtp_opt_in() {
  if [[ "${inference_GGUF_ALLOW_MTP:-0}" != "1" ]]; then
    echo "ERROR: MTP fetch profiles require inference_GGUF_ALLOW_MTP=1 (unsloth/Qwen3.6-27B-MTP-GGUF)." >&2
    echo "  MTP needs: draft-mtp coordinator flags, llama.cpp ~b9180+ hub rebuild, rm gguf27." >&2
    echo "  Non-MTP production: PROFILE=code-q8 or inference_GGUF_PROFILE=q8 (Q8_0)." >&2
    echo "  Multi-slot Q4 rollback: PROFILE=code-ud or inference_GGUF_PROFILE=ud-q4kxl." >&2
    exit 1
  fi
}

# ── Profile: code-mtp (Qwen3.6-27B MTP GGUF — multi-token prediction) ─────
fetch_code_mtp() {
  require_mtp_opt_in
  # unsloth/Qwen3.6-27B-MTP-GGUF — needs draft-mtp coordinator + llama.cpp MTP build.
  REPO="${REPO:-unsloth/Qwen3.6-27B-MTP-GGUF}"
  MODEL_LEAD="${MODEL_LEAD:-Qwen3.6-27B-Q4_K_M.gguf}"
  HF_INCLUDE="${HF_INCLUDE:-Qwen3.6-27B-Q4_K_M.gguf}"

  fetch_multi_or_single "$REPO" "$MODEL_LEAD" "$HF_INCLUDE"
}

# ── Profile: code-mtp-ud (MTP repo + UD quant — NOT the non-MTP ud-q4kxl path) ─
fetch_code_mtp_ud() {
  require_mtp_opt_in
  REPO="${REPO:-unsloth/Qwen3.6-27B-MTP-GGUF}"
  MODEL_LEAD="${MODEL_LEAD:-Qwen3.6-27B-UD-Q4_K_XL.gguf}"
  HF_INCLUDE="${HF_INCLUDE:-Qwen3.6-27B-UD-Q4_K_XL.gguf}"

  fetch_multi_or_single "$REPO" "$MODEL_LEAD" "$HF_INCLUDE"
}

# ── Profile: moe35 (Qwen3.6-35B-A3B Q4_K_M for G-rev RPC pool) ───────────────
fetch_moe35() {
  REPO="${REPO:-unsloth/Qwen3.6-35B-A3B-GGUF}"
  MODEL_LEAD="${MODEL_LEAD:-Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}"
  HF_INCLUDE="${HF_INCLUDE:-Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}"

  fetch_multi_or_single "$REPO" "$MODEL_LEAD" "$HF_INCLUDE"
}

# ── Profile: agentic alt (Qwen3-Coder-Next-80B-A3B Q4_K_M, multi-shard) ───
fetch_agentic() {
  REPO="${REPO:-Qwen/Qwen3-Coder-Next-GGUF}"
  MODEL_LEAD="${MODEL_LEAD:-Qwen3-Coder-Next-Q4_K_M/Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf}"
  HF_INCLUDE="${HF_INCLUDE:-Qwen3-Coder-Next-Q4_K_M/*.gguf}"

  lead="$MODELS_DIR/$MODEL_LEAD"
  if [[ -f "$lead" ]]; then
    echo "Already present: $lead ($(du -h "$lead" | awk '{print $1}'))"
    echo "Directory total:" "$(du -sh "$(dirname "$lead")" | awk '{print $1}')"
    exit 0
  fi

  if command -v huggingface-cli >/dev/null 2>&1; then
    echo "Fetching $REPO include '$HF_INCLUDE' -> $MODELS_DIR (huggingface-cli)"
    huggingface-cli download "$REPO" \
      --include "$HF_INCLUDE" \
      --local-dir "$MODELS_DIR" \
      --local-dir-use-symlinks False
  elif [[ -f "$HTTP_FETCH_SH" ]]; then
    # shellcheck source=/dev/null
    source "$HTTP_FETCH_SH"
    echo "Fetching $REPO Q4_K_M shards via http_fetch (4 files) -> $MODELS_DIR"
    local_dir_rel="Qwen3-Coder-Next-Q4_K_M"
    for i in 1 2 3 4; do
      printf -v shard 'Qwen3-Coder-Next-Q4_K_M-%05d-of-00004.gguf' "$i"
      rel="${local_dir_rel}/${shard}"
      dest="$MODELS_DIR/$rel"
      url="https://huggingface.co/${REPO}/resolve/main/${rel}?download=true"
      echo "  [$i/4] $shard" >&2
      http_fetch_to "$url" "$dest"
    done
  else
    echo "Install huggingface-cli or ensure repo scripts/lib/http_fetch.sh exists." >&2
    exit 1
  fi

  verify_lead "$REPO" "$MODEL_LEAD"
}

# ── Shared fetch helper (single file or HF include glob) ────────────────────
fetch_multi_or_single() {
  local repo="$1"
  local model_lead="$2"
  local hf_include="$3"

  lead="$MODELS_DIR/$model_lead"

  if [[ "${VERIFY_ONLY:-0}" == "1" ]]; then
    verify_lead "$repo" "$model_lead"
    exit 0
  fi

  if [[ -f "$lead" ]]; then
    if [[ "${REFRESH:-0}" == "1" ]]; then
      echo "REFRESH=1: removing $lead"
      rm -f "$lead"
    else
      # Split GGUF: only skip early if every shard is present (truncated lead must not skip).
      local all_shards=1
      if [[ "$model_lead" =~ ^(.*)-00001-of-([0-9]+)\.gguf$ ]]; then
        local prefix0="${BASH_REMATCH[1]}"
        local total0=$((10#${BASH_REMATCH[2]}))
        local j shard0
        for ((j = 1; j <= total0; j++)); do
          printf -v shard0 '%s-%05d-of-%05d.gguf' "$prefix0" "$j" "$total0"
          if [[ ! -f "$MODELS_DIR/$shard0" ]]; then
            all_shards=0
            break
          fi
        done
      fi
      if [[ "$all_shards" -eq 1 ]]; then
        echo "Already present: $lead ($(du -h "$lead" | awk '{print $1}'))"
        if [[ -d "$(dirname "$lead")" ]]; then
          echo "Directory total:" "$(du -sh "$(dirname "$lead")" | awk '{print $1}')"
        fi
        verify_lead "$repo" "$model_lead"
        exit 0
      fi
      echo "Lead present but split set incomplete -- continuing fetch (aria2 --continue)." >&2
    fi
  fi

  _fetch_via_aria2_http() {
    [[ -f "$HTTP_FETCH_SH" ]] || return 1
    # shellcheck source=/dev/null
    source "$HTTP_FETCH_SH"
    mkdir -p "$(dirname "$lead")"
    # Official Qwen/large GGUFs are often split: name-00001-of-00012.gguf
    if [[ "$model_lead" =~ ^(.*)-00001-of-([0-9]+)\.gguf$ ]]; then
      local prefix="${BASH_REMATCH[1]}"
      local total_raw="${BASH_REMATCH[2]}"
      local total=$((10#$total_raw))
      local i shard url dest
      echo "Fetching $repo split GGUF ($total shards) via http_fetch/aria2 -> $MODELS_DIR" >&2
      for ((i = 1; i <= total; i++)); do
        printf -v shard '%s-%05d-of-%05d.gguf' "$prefix" "$i" "$total"
        dest="$MODELS_DIR/$shard"
        url="https://huggingface.co/${repo}/resolve/main/${shard}?download=true"
        echo "  [$i/$total] $shard" >&2
        if [[ -f "$dest" && "${REFRESH:-0}" == "1" ]]; then
          rm -f "$dest" "${dest}.aria2"
        fi
        # Always call http_fetch: aria2 --continue resumes partials (do not skip truncated files).
        http_fetch_to "$url" "$dest"
      done
    else
      echo "Fetching $repo / $model_lead via http_fetch/aria2 -> $MODELS_DIR"
      url="https://huggingface.co/${repo}/resolve/main/${model_lead}?download=true"
      http_fetch_to "$url" "$lead"
    fi
  }

  if [[ "${FETCH_GGUF_ARIA2_FIRST:-1}" == "1" ]]; then
    if ! _fetch_via_aria2_http; then
      echo "ERROR: hub GGUF fetch requires aria2 (aria2c or ARIA2_RPC_URL)." >&2
      echo "  Source deploy/cluster-members/hub/aria2-env.sh and ensure Dockge aria2 is up." >&2
      echo "  See docs/HTTP_DOWNLOADS.md — curl is not a download fallback." >&2
      echo "  Or set FETCH_GGUF_ARIA2_FIRST=0 to use hf CLI only (not recommended on hub)." >&2
      exit 1
    fi
  elif declare -f alfa_hf_download_gguf >/dev/null 2>&1 && alfa_hf_cli >/dev/null 2>&1; then
    alfa_hf_download_gguf "$repo" "$hf_include" "$MODELS_DIR"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    echo "Fetching $repo include '$hf_include' -> $MODELS_DIR (huggingface-cli)" >&2
    huggingface-cli download "$repo" \
      --include "$hf_include" \
      --local-dir "$MODELS_DIR" \
      --local-dir-use-symlinks False
  elif _fetch_via_aria2_http; then
    :
  else
    echo "Install aria2 (aria2c or ARIA2_RPC_URL) via docs/HTTP_DOWNLOADS.md, or hf CLI." >&2
    exit 1
  fi

  verify_lead "$repo" "$model_lead"
}

verify_lead() {
  local repo="$1"
  local model_lead="$2"
  lead="$MODELS_DIR/$model_lead"
  if [[ ! -f "$lead" ]]; then
    echo "ERROR: expected file missing: $lead" >&2
    exit 1
  fi
  if declare -f alfa_hf_verify_gguf >/dev/null 2>&1; then
    alfa_hf_verify_gguf "$repo" "$MODELS_DIR" "$model_lead" || exit 1
  fi
  echo "Done."
  ls -lh "$lead"
  if [[ -d "$(dirname "$lead")" ]]; then
    du -sh "$(dirname "$lead")"
  fi
}

# ── Profile: draft (E2 speculative — Qwen2.5-0.5B-Instruct Q4_K_M) ─────────
fetch_draft() {
  REPO="${REPO:-Qwen/Qwen2.5-0.5B-Instruct-GGUF}"
  local canonical="Qwen2.5-0.5B-Instruct-Q4_K_M.gguf"
  local hf_name="qwen2.5-0.5b-instruct-q4_k_m.gguf"
  HF_INCLUDE="${HF_INCLUDE:-*Q4_K_M*.gguf}"

  if [[ -f "$MODELS_DIR/$canonical" ]]; then
    echo "Already present: $MODELS_DIR/$canonical"
    ls -lh "$MODELS_DIR/$canonical"
    exit 0
  fi

  if command -v huggingface-cli >/dev/null 2>&1; then
    fetch_multi_or_single "$REPO" "$canonical" "$HF_INCLUDE"
  elif [[ -f "$HTTP_FETCH_SH" ]]; then
    # shellcheck source=/dev/null
    source "$HTTP_FETCH_SH"
    echo "Fetching $REPO / $hf_name via http_fetch -> $MODELS_DIR/$canonical"
    url="https://huggingface.co/${REPO}/resolve/main/${hf_name}?download=true"
    http_fetch_to "$url" "$MODELS_DIR/$canonical"
    verify_lead "$REPO" "$canonical"
  else
    echo "Install huggingface-cli or ensure repo scripts/lib/http_fetch.sh exists." >&2
    exit 1
  fi

  if [[ ! -f "$MODELS_DIR/$canonical" ]]; then
    local found=""
    found="$(find "$MODELS_DIR" -maxdepth 1 -type f -iname '*q4_k_m*.gguf' | head -1 || true)"
    if [[ -n "$found" && "$found" != "$MODELS_DIR/$canonical" ]]; then
      ln -sf "$(basename "$found")" "$MODELS_DIR/$canonical"
      echo "Linked $(basename "$found") -> $canonical"
    fi
  fi

  verify_lead "$REPO" "$canonical"
}

# hub_hub_models.sh pull gguf passes REPO + MODEL_LEAD (+ HF_INCLUDE).
if [[ -n "${REPO:-}" && -n "${MODEL_LEAD:-}" ]]; then
  fetch_multi_or_single "$REPO" "$MODEL_LEAD" "${HF_INCLUDE:-$MODEL_LEAD}"
  exit 0
fi

case "$PROFILE" in
  chat)         fetch_chat ;;
  code)         fetch_code ;;
  code-ud)      fetch_code_ud ;;
  code-q8)      fetch_code_q8 ;;
  code-mtp)     fetch_code_mtp ;;
  code-mtp-ud)  fetch_code_mtp_ud ;;
  moe35)        fetch_moe35 ;;
  agentic)      fetch_agentic ;;
  draft)        fetch_draft ;;
  *)
    echo "ERROR: unknown PROFILE='$PROFILE' (use chat, code, code-ud, code-q8, code-mtp, code-mtp-ud, moe35, agentic, draft)" >&2
    exit 1
    ;;
esac
