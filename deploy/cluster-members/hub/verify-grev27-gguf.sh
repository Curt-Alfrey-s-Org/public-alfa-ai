#!/usr/bin/env bash
# Verify Qwen3.8-27B GGUF on hub hub (hub) via official hf cache verify.
#
# Official: https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-cache-verify
#
# Usage (on hub):
#   bash deploy/cluster-members/hub/verify-grev27-gguf.sh
#   MODELS_DIR=/mnt/hub/alfa-ai/llama-cpp/models bash .../verify-grev27-gguf.sh
set -euo pipefail

HOST_IPS="$(hostname -I 2>/dev/null || true)"
if [[ -n "$HOST_IPS" ]] && [[ "$HOST_IPS" != *"hub"* ]] && [[ "${ALLOW_NON_HUB_VERIFY:-0}" != "1" ]]; then
  echo "ERROR: run on hub (hub hub) only, or set ALLOW_NON_HUB_VERIFY=1" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=deploy/cluster-members/_common/hf-gguf-hub.sh
source "$REPO_ROOT/deploy/cluster-members/_common/hf-gguf-hub.sh"

MODELS_DIR="${MODELS_DIR:-/mnt/hub/alfa-ai/llama-cpp/models}"
REPO="${REPO:-unsloth/Qwen3.8-27B-GGUF}"
LEAD="${LEAD:-Qwen3.8-27B-Q8_0.gguf}"

echo "== G-rev27 hub verify =="
echo "  MODELS_DIR=$MODELS_DIR"
echo "  REPO=$REPO"
echo "  LEAD=$LEAD"
alfa_hf_verify_gguf "$REPO" "$MODELS_DIR" "$LEAD"
echo "OK: $MODELS_DIR/$LEAD verified against Hub checksums"
