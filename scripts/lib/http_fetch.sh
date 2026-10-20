#!/usr/bin/env bash
# Single-file HTTP(S) fetch — aria2 only (no curl fallback for file bodies).
#
# 1) aria2c on PATH  — multi-connection (-x/-s), --continue for partials
# 2) ARIA2_RPC_URL   — remote aria2 JSON-RPC (see scripts/lib/aria2_jsonrpc_fetch.py)
#
# Curl is NOT used for downloads. Truncated multi-GB hub files from curl
# HTTP/2 CANCEL are unacceptable. Short health probes may still use curl elsewhere.
#
# Official aria2 continue: https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-c
#
# NOT used for: ollama pull / docker registry / git-lfs (different protocols).
#
# Environment (optional):
#   ARIA2_MODE           auto | cli | rpc | curl
#                        auto (default) = cli then rpc, never curl
#                        curl = emergency only (not for hub GGUF)
#   ARIA2_CONN           connections for aria2c -x/-s (default 16)
#   ARIA2_RPC_URL        e.g. http://hub/jsonrpc
#   ARIA2_RPC_KEY     required for rpc mode (no default)
#   ARIA2_RPC_DIR        server-side dir (default /downloads)
#   ARIA2_HOST_STAGING   host path bound to that dir (default /mnt/hub/alfa-ai/models/downloads)
#   HF_TOKEN / HUGGING_FACE_HUB_TOKEN  Bearer for HF (if only the latter is set, it is used)
#   HTTP_FETCH_PROGRESS  1 (default) show aria2 summary / RPC bytes on stderr when TTY; 0 to silence
#   HTTP_FETCH_SKIP_EXISTING  1 = skip if dest exists (default off — resume via aria2 -c)
#
# Usage:
#   source "$(dirname "$0")/http_fetch.sh"   # or path to this file
#   http_fetch_to "https://…/file.bin" /path/to/file.bin
#
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

http_fetch_to() {
  local url="$1" dest="$2"
  if [[ -z "${HF_TOKEN:-}" && -n "${HUGGING_FACE_HUB_TOKEN:-}" ]]; then
    export HF_TOKEN="$HUGGING_FACE_HUB_TOKEN"
  fi
  local mode="${ARIA2_MODE:-auto}"
  local d out conn="${ARIA2_CONN:-16}"
  d="$(dirname "$dest")"
  out="$(basename "$dest")"
  mkdir -p "$d"

  if [[ -f "$dest" && "${HTTP_FETCH_SKIP_EXISTING:-0}" == "1" ]]; then
    echo "http_fetch_to: already exists $dest (HTTP_FETCH_SKIP_EXISTING=1)"
    return 0
  fi

  _use_cli() {
    command -v aria2c >/dev/null 2>&1
  }
  _use_rpc() {
    [[ -n "${ARIA2_RPC_URL:-}" ]] && command -v python3 >/dev/null 2>&1
  }

  local try_cli=0 try_rpc=0 try_curl=0
  local progress_tty=0
  if [[ -t 2 && "${HTTP_FETCH_PROGRESS:-1}" != "0" ]]; then
    progress_tty=1
  fi

  case "$mode" in
    auto)
      try_cli=1
      try_rpc=1
      ;;
    cli) try_cli=1 ;;
    rpc) try_rpc=1 ;;
    curl)
      # Emergency only — never used by hub GGUF seed paths.
      try_curl=1
      ;;
    *) echo "ERROR: bad ARIA2_MODE=$mode (use auto|cli|rpc|curl)" >&2; return 2 ;;
  esac

  if [[ "$try_cli" -eq 1 ]] && _use_cli; then
    echo "http_fetch_to: aria2c (-x$conn -s$conn -c) -> $dest" >&2
    local -a hdr=()
    [[ -n "${HF_TOKEN:-}" ]] && hdr=(--header="Authorization: Bearer ${HF_TOKEN}")
    local -a a2extra=()
    [[ "$progress_tty" -eq 1 ]] && a2extra=(--summary-interval=1)
    # -c/--continue: resume partial HTTP(S) downloads (official aria2c manual).
    aria2c --allow-overwrite=true --auto-file-renaming=false \
      --continue=true \
      -x "$conn" -s "$conn" -k 1M \
      "${a2extra[@]}" \
      "${hdr[@]}" \
      --dir="$d" --out="$out" "$url"
    [[ -f "$dest" ]]
    return
  fi

  if [[ "$try_rpc" -eq 1 ]] && _use_rpc; then
    echo "http_fetch_to: aria2 JSON-RPC -> $dest" >&2
    if [[ -z "${ARIA2_RPC_KEY:-}" ]]; then
      echo "http_fetch_to: ARIA2_RPC_KEY is not set; cannot use aria2 RPC (see deploy/aria2/README.md)" >&2
      return 1
    fi
    export ARIA2_RPC_URL ARIA2_RPC_KEY
    export ARIA2_RPC_DIR="${ARIA2_RPC_DIR:-/downloads}"
    export ARIA2_HOST_STAGING="${ARIA2_HOST_STAGING:-/mnt/hub/alfa-ai/models/downloads}"
    python3 "$_LIB_DIR/aria2_jsonrpc_fetch.py" "$url" "$dest"
    return
  fi

  if [[ "$try_curl" -eq 1 ]]; then
    echo "http_fetch_to: curl (ARIA2_MODE=curl emergency) -> $dest" >&2
    local -a cu=(-fSL --retry 3 --retry-delay 2 -o "$dest")
    if [[ "$progress_tty" -eq 1 ]]; then
      cu+=(--progress-bar)
    else
      cu+=(-s)
    fi
    if [[ -n "${HF_TOKEN:-}" ]]; then
      curl "${cu[@]}" -H "Authorization: Bearer ${HF_TOKEN}" "$url"
    else
      curl "${cu[@]}" "$url"
    fi
    return
  fi

  echo "ERROR: http_fetch_to: aria2 required but unavailable." >&2
  echo "  Install aria2c on PATH, or set ARIA2_RPC_URL + python3 (Dockge deploy/aria2 on hub)." >&2
  echo "  On hub: source deploy/cluster-members/hub/aria2-env.sh && ensure aria2 stack is up." >&2
  echo "  Curl is not a fallback for hub/GGUF downloads (see docs/HTTP_DOWNLOADS.md)." >&2
  return 1
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  http_fetch_to "${1:-}" "${2:-}"
fi
