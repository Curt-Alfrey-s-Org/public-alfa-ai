#!/usr/bin/env bash
# Convert pool-7b QLoRA checkpoint to LoRA GGUF on hub hub (hub-first).
#
# Base GGUF must match Qwen2.5-Coder-7B-Instruct (same family as train checkpoint).
# Official: convert_lora_to_gguf.py
#   https://github.com/ggml-org/llama.cpp/blob/master/convert_lora_to_gguf.py
#
# Usage (operator on hub). Default stays v1. For v2 eval:
#   sudo env CHECKPOINT_DIR=/mnt/hub/alfa-ai/training/alfa-train/checkpoints/pool-7b-qlora-v2 \
#     ADAPTER_ID=pool-7b-qlora-v2 \
#     bash deploy/cluster-members/hub/convert-7b-qlora-to-gguf.sh
#
# Optional env:
#   CHECKPOINT_DIR=/mnt/hub/alfa-ai/training/alfa-train/checkpoints/pool-7b-qlora-v1
#   ADAPTER_ID=pool-7b-qlora-v1
#   BASE_GGUF=/mnt/hub/alfa-ai/llama-cpp/models/qwen25-coder-7b/Qwen2.5-Coder-7B-Instruct-Q8_0.gguf
#   OUT_LORA=/mnt/hub/alfa-ai/llama-cpp/lora/qwen25-coder-7b/pool-7b-qlora-v1.gguf
#   FORCE_BASE_CONVERT=1   # re-run HF->GGUF even if BASE_GGUF exists
#   FORCE_LORA_CONVERT=1   # overwrite an existing OUT_LORA GGUF
#   CONVERT_DOCKER_IMAGE=axolotlai/axolotl-uv:main-py3.12-cu130-2.12.0
#     hub host python often lacks torch; auto-uses this image when import fails.
#
# Docs: docs/operations/ALFA_7B_SERVE_ALONGSIDE_27B.md
# orchestrator wrapper: Invoke-AlfaTrain7bEvalCycle.ps1 (sudo env ... bash this file; hub file may be 644).
set -euo pipefail

HUB_ROOT="/mnt/hub/alfa-ai"
CONVERT_DOCKER_IMAGE="${CONVERT_DOCKER_IMAGE:-}"
CONVERT_DOCKER_IMAGE_DEFAULT="${CONVERT_DOCKER_IMAGE_DEFAULT:-axolotlai/axolotl-uv:main-py3.12-cu130-2.12.0}"
VENDOR_MOUNT="/vendor"

hub_relpath() {
  local p="$1"
  case "$p" in
    "$HUB_ROOT"/*) printf '/hub/%s' "${p#"$HUB_ROOT"/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

resolve_convert_docker() {
  if [[ -n "$CONVERT_DOCKER_IMAGE" ]]; then
    return 0
  fi
  if python3 -c 'import torch' 2>/dev/null; then
    CONVERT_DOCKER_IMAGE=""
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    CONVERT_DOCKER_IMAGE="$CONVERT_DOCKER_IMAGE_DEFAULT"
    echo "== host python lacks torch; using docker $CONVERT_DOCKER_IMAGE =="
    return 0
  fi
  echo "ERROR: host python lacks torch and docker is unavailable" >&2
  return 1
}

run_convert_py() {
  local script_path="$1"
  shift
  resolve_convert_docker
  if [[ -z "$CONVERT_DOCKER_IMAGE" ]]; then
    python3 "$script_path" "$@"
    return $?
  fi
  local script_dir
  script_dir="$(dirname "$script_path")"
  local script_base
  script_base="$(basename "$script_path")"
  local -a docker_args=(run --rm)
  docker_args+=(-v "${HUB_ROOT}:/hub")
  docker_args+=(-v "${script_dir}:${VENDOR_MOUNT}:ro")
  local -a inner=("$VENDOR_MOUNT/$script_base")
  local arg mapped
  for arg in "$@"; do
    mapped="$(hub_relpath "$arg")"
    inner+=("$mapped")
  done
  docker "${docker_args[@]}" "$CONVERT_DOCKER_IMAGE" python3 "${inner[@]}"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VENDOR="${LLAMA_CPP_VENDOR:-$REPO_ROOT/deploy/llamacpp-rpc/vendor/llama.cpp}"
CONVERT_LORA="$VENDOR/convert_lora_to_gguf.py"
CONVERT_HF="$VENDOR/convert_hf_to_gguf.py"

HUB_MODELS="/mnt/hub/alfa-ai/llama-cpp/models/qwen25-coder-7b"
HUB_LORA="/mnt/hub/alfa-ai/llama-cpp/lora/qwen25-coder-7b"
HF_HUB="/mnt/hub/alfa-ai/models/huggingface/hub/models--Qwen--Qwen2.5-Coder-7B-Instruct"

CHECKPOINT_DIR="${CHECKPOINT_DIR:-/mnt/hub/alfa-ai/training/alfa-train/checkpoints/pool-7b-qlora-v1}"
ADAPTER_ID="${ADAPTER_ID:-pool-7b-qlora-v1}"
BASE_GGUF="${BASE_GGUF:-$HUB_MODELS/Qwen2.5-Coder-7B-Instruct-Q8_0.gguf}"
OUT_LORA="${OUT_LORA:-$HUB_LORA/${ADAPTER_ID}.gguf}"
VENDOR_TGZ="${VENDOR_TGZ:-/mnt/hub/alfa-ai/smb-scratch/cluster_members/_common/source-tarballs/llama.cpp.tar.gz}"

if [[ ! -d "$CHECKPOINT_DIR" ]]; then
  echo "ERROR: missing checkpoint dir $CHECKPOINT_DIR" >&2
  echo "  Train must finish and write PEFT adapter to hub first." >&2
  exit 1
fi

if [[ ! -f "$CHECKPOINT_DIR/adapter_config.json" ]]; then
  echo "ERROR: missing adapter_config.json under $CHECKPOINT_DIR" >&2
  exit 1
fi

ckpt_id="$(basename "$CHECKPOINT_DIR")"
if [[ "$ckpt_id" != "$ADAPTER_ID" ]]; then
  echo "ERROR: CHECKPOINT_DIR basename ($ckpt_id) must equal ADAPTER_ID ($ADAPTER_ID)" >&2
  echo "  v2 eval: sudo env CHECKPOINT_DIR=.../pool-7b-qlora-v2 ADAPTER_ID=pool-7b-qlora-v2 bash $0" >&2
  echo "  Refusing so default ADAPTER_ID cannot overwrite pool-7b-qlora-v1.gguf." >&2
  exit 1
fi
if [[ -f "$OUT_LORA" && "${FORCE_LORA_CONVERT:-0}" != "1" ]]; then
  echo "ERROR: $OUT_LORA already exists (set FORCE_LORA_CONVERT=1 to overwrite)" >&2
  exit 1
fi

mkdir -p "$HUB_MODELS" "$HUB_LORA"

if [[ ! -f "$CONVERT_LORA" ]]; then
  if [[ -f "$VENDOR_TGZ" ]]; then
    EXTRACT="/tmp/alfa-llama-cpp-convert-$$"
    echo "== unpack llama.cpp vendor tarball for convert =="
    mkdir -p "$EXTRACT"
    tar -xzf "$VENDOR_TGZ" -C "$EXTRACT"
    CONVERT_LORA="$(find "$EXTRACT" -name convert_lora_to_gguf.py -print -quit)"
    CONVERT_HF="$(find "$EXTRACT" -name convert_hf_to_gguf.py -print -quit)"
  fi
fi
if [[ ! -f "${CONVERT_LORA:-}" ]]; then
  echo "ERROR: missing convert_lora_to_gguf.py (vendor tree or $VENDOR_TGZ)" >&2
  exit 1
fi

hf_snapshot=""
if [[ -d "$HF_HUB/snapshots" ]]; then
  hf_snapshot="$(find "$HF_HUB/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
fi

# --- Base GGUF (one-time on hub) ---
if [[ ! -f "$BASE_GGUF" || "${FORCE_BASE_CONVERT:-0}" == "1" ]]; then
  if [[ ! -f "${CONVERT_HF:-}" ]]; then
    echo "ERROR: missing convert_hf_to_gguf.py for base GGUF conversion" >&2
    exit 1
  fi
  if [[ -z "$hf_snapshot" || ! -f "$hf_snapshot/config.json" ]]; then
    echo "ERROR: HF cache missing under $HF_HUB" >&2
    echo "  Seed on hub: sudo bash scripts/hub_hub_models.sh pull hf Qwen/Qwen2.5-Coder-7B-Instruct" >&2
    exit 1
  fi
  echo "== convert HF base -> GGUF Q8_0 =="
  run_convert_py "$CONVERT_HF" "$hf_snapshot" \
    --outfile "$BASE_GGUF" \
    --outtype q8_0
  chmod a+r "$BASE_GGUF"
  echo "OK: base GGUF $BASE_GGUF ($(du -sh "$BASE_GGUF" | awk '{print $1}'))"
else
  echo "OK: base GGUF already present: $BASE_GGUF"
fi

# --- LoRA GGUF ---
echo "== convert PEFT adapter -> LoRA GGUF =="
lora_args=("$CHECKPOINT_DIR" --outfile "$OUT_LORA" --outtype f16)
if [[ -n "$hf_snapshot" && -f "$hf_snapshot/config.json" ]]; then
  lora_args+=(--base "$hf_snapshot")
fi
run_convert_py "$CONVERT_LORA" "${lora_args[@]}"
chmod a+r "$OUT_LORA"
echo "OK: LoRA GGUF $OUT_LORA ($(du -sh "$OUT_LORA" | awk '{print $1}'))"

echo ""
echo "NFS clients:"
echo "  base:  /mnt/cluster/llama-cpp/models/qwen25-coder-7b/$(basename "$BASE_GGUF")"
echo "  lora:  /mnt/cluster/llama-cpp/lora/qwen25-coder-7b/$(basename "$OUT_LORA")"
echo "Next: sequential eval on gaming-c:8470 (Start-Alfa7bServe.ps1 -NoLora then -LoraGguf)."
echo "Then live FAQ Yes/No on :8470. Do not set LLAMACPP_7B_URL unless the operator asks after that chat."
