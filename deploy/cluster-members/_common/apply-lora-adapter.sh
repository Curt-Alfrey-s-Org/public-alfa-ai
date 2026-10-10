#!/usr/bin/env bash
# Hotswap LoRA scale on a running llama-server (optional; coordinator restart preferred).
#
# Requires server started with adapters pre-loaded (--lora-init-without-apply).
# Default deploy uses --lora at cold start via run-llama-server-coordinator.sh instead.
#
# Usage:
#   bash deploy/cluster-members/_common/apply-lora-adapter.sh http://127.0.0.1:31360 0 1.0
#
# Official: https://github.com/ggml-org/llama.cpp/pull/8857
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:31360}"
ADAPTER_ID="${2:-0}"
SCALE="${3:-1.0}"

curl -fsS "${BASE_URL%/}/lora-adapters" | head -c 2000
echo ""
curl -fsS -X POST "${BASE_URL%/}/lora-adapters" \
  -H "Content-Type: application/json" \
  -d "[{\"id\": ${ADAPTER_ID}, \"scale\": ${SCALE}}]"
echo ""
