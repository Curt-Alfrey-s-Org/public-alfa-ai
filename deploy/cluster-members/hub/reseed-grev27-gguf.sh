#!/usr/bin/env bash
# Remove, re-download, and verify Qwen3.8-27B (Q8_0 production policy) on hub hub (hub only).
#
# Official download: https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-download
# Official verify:   https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-cache-verify
#
# Usage (on hub):
#   bash deploy/cluster-members/hub/reseed-grev27-gguf.sh
# Or via hub manager:
#   sudo bash scripts/hub_hub_models.sh rm gguf27
#   sudo bash scripts/hub_hub_models.sh pull gguf27
set -euo pipefail

HOST_IPS="$(hostname -I 2>/dev/null || true)"
if [[ -n "$HOST_IPS" ]] && [[ "$HOST_IPS" != *"hub"* ]]; then
  echo "ERROR: run on hub (hub hub) only" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MODELS_DIR="${MODELS_DIR:-/mnt/hub/alfa-ai/llama-cpp/models}"
LEAD="${LEAD:-Qwen3.8-27B-Q8_0.gguf}"
DEST="$MODELS_DIR/$LEAD"
FETCH="$REPO_ROOT/deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh"

TS="$(date +%Y%m%d-%H%M%S)"
LOG="/tmp/reseed-grev27-${TS}.log"
exec > >(tee "$LOG") 2>&1

echo "== G-rev27 hub reseed (remove + pull + verify) =="
echo "  log: $LOG"

if [[ -f "$DEST" ]]; then
  echo "Removing existing: $DEST ($(du -h "$DEST" | awk '{print $1}'))"
  rm -f "$DEST"
else
  echo "No existing file at $DEST"
fi

if [[ ! -f "$FETCH" ]]; then
  echo "ERROR: missing $FETCH (git pull on hub repo clone)" >&2
  exit 1
fi

MODELS_DIR="$MODELS_DIR" PROFILE=code-q8 REFRESH=1 bash "$FETCH"

bash "$SCRIPT_DIR/verify-grev27-gguf.sh"

echo ""
echo "Reseed complete. Workers read via NFS: /mnt/cluster/llama-cpp/models/$LEAD"
echo "SCP log to inference hub (optional): scp $LOG operator@orchestrator:/home/operator/alfa-ai/logs/hub-seed/"
