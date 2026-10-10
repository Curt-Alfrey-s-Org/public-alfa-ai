#!/usr/bin/env bash
# HF GGUF hub helpers — official hf CLI only.
#
# Download: https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-download
# Verify:   https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-cache-verify
#
# Usage (source from other scripts):
#   source deploy/cluster-members/_common/hf-gguf-hub.sh
#   alfa_hf_download_gguf REPO INCLUDE LOCAL_DIR
#   alfa_hf_verify_gguf REPO LOCAL_DIR [LEAD_FILE]
set -euo pipefail

alfa_hf_cli() {
  if command -v hf >/dev/null 2>&1; then
    printf '%s\n' hf
    return 0
  fi
  if command -v huggingface-cli >/dev/null 2>&1; then
    printf '%s\n' huggingface-cli
    return 0
  fi
  return 1
}

alfa_hf_token_args() {
  local -a args=()
  if [[ -n "${HF_TOKEN:-}" ]]; then
    args+=(--token "$HF_TOKEN")
  elif [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    args+=(--token "$HUGGING_FACE_HUB_TOKEN")
  fi
  printf '%s\n' "${args[@]:-}"
}

# Download GGUF include pattern into LOCAL_DIR (flat layout, no symlinks).
alfa_hf_download_gguf() {
  local repo="$1"
  local include="$2"
  local local_dir="$3"
  local cli
  cli="$(alfa_hf_cli)" || {
    echo "ERROR: install hf CLI (https://huggingface.co/docs/huggingface_hub/en/guides/cli)" >&2
    return 1
  }
  mkdir -p "$local_dir"
  local -a token_args=()
  if [[ -n "${HF_TOKEN:-}" ]]; then
    token_args=(--token "$HF_TOKEN")
  elif [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    token_args=(--token "$HUGGING_FACE_HUB_TOKEN")
  fi
  echo "Fetching $repo include '$include' -> $local_dir ($cli download)"
  if [[ "$cli" == hf ]]; then
    hf download "$repo" \
      --include "$include" \
      --local-dir "$local_dir" \
      "${token_args[@]}"
  else
    huggingface-cli download "$repo" \
      --include "$include" \
      --local-dir "$local_dir" \
      --local-dir-use-symlinks False \
      "${token_args[@]}"
  fi
}

# Verify LOCAL_DIR against Hub checksums (official hf cache verify).
alfa_hf_verify_gguf() {
  local repo="$1"
  local local_dir="$2"
  local lead_file="${3:-}"
  local cli
  cli="$(alfa_hf_cli)" || {
    echo "WARN: hf CLI missing — skipping hf cache verify (file presence only)" >&2
    if [[ -n "$lead_file" && ! -f "$local_dir/$lead_file" ]]; then
      echo "ERROR: expected file missing: $local_dir/$lead_file" >&2
      return 1
    fi
    return 0
  }
  if [[ "$cli" != hf ]]; then
    echo "WARN: huggingface-cli has no cache verify — need 'hf' CLI for checksum verify" >&2
    if [[ -n "$lead_file" && ! -f "$local_dir/$lead_file" ]]; then
      echo "ERROR: expected file missing: $local_dir/$lead_file" >&2
      return 1
    fi
    [[ -n "$lead_file" ]] && ls -lh "$local_dir/$lead_file"
    return 0
  fi
  local -a token_args=()
  if [[ -n "${HF_TOKEN:-}" ]]; then
    token_args=(--token "$HF_TOKEN")
  elif [[ -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    token_args=(--token "$HUGGING_FACE_HUB_TOKEN")
  fi
  echo "Verifying $repo in $local_dir (hf cache verify)"
  hf cache verify "$repo" \
    --local-dir "$local_dir" \
    --fail-on-missing-files \
    --fail-on-extra-files \
    "${token_args[@]}"
  if [[ -n "$lead_file" ]]; then
    [[ -f "$local_dir/$lead_file" ]] || {
      echo "ERROR: lead file missing after verify: $local_dir/$lead_file" >&2
      return 1
    }
    ls -lh "$local_dir/$lead_file"
    du -sh "$local_dir"
  fi
}
