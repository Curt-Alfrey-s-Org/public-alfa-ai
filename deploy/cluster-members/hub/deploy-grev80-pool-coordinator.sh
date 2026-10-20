#!/usr/bin/env bash
# Deploy exclusive Qwen3-Coder-Next Q5_K_M RPC coordinator on hub (:31360).
#
# Prerequisites:
#   - Full-mesh shards in inference_SHARDS_FILE
#   - Hub GGUF: Qwen3-Coder-Next-Q5_K_M/ (pull gguf)
#   - llama.cpp image with qwen3next (not b8552 alone)
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/deploy-grev80-pool-coordinator.sh
#
# Docs: docs/GREV80_80B_OPERATOR.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
COMMON="$REPO_DIR/deploy/cluster-members/_common"
SHARDS_FILE="${inference_SHARDS_FILE:-}"
if [[ -z "$SHARDS_FILE" ]]; then
  if [[ -f "$LLC/inference-shards.active.env" ]]; then
    SHARDS_FILE="$LLC/inference-shards.active.env"
  else
    SHARDS_FILE="$LLC/inference-shards.env"
  fi
fi
export inference_SHARDS_FILE="$SHARDS_FILE"

if [[ ! -d "$LLC" ]]; then
  echo "ERROR: missing $LLC" >&2
  exit 1
fi
sudo bash "$COMMON/preflight-docker-engine.sh"

sudo inference_SHARDS_FILE="$inference_SHARDS_FILE" bash "$SCRIPT_DIR/write-grev80-pool-env.sh"

sudo FORCE_HUB_RPC_LOAD="${FORCE_HUB_RPC_LOAD:-}" bash "$COMMON/load-llamacpp-rpc-from-hub.sh"

if [[ "${inference_SKIP_INITIAL_VERIFY:-0}" != "1" ]]; then
  echo "== GREV80: verify RPC shards ($inference_SHARDS_FILE) =="
  inference_VERIFY_RETRIES="${inference_VERIFY_RETRIES:-30}" bash "$COMMON/verify-inference-shards.sh" "$inference_SHARDS_FILE"
else
  echo "== GREV80: skip initial shard verify (inference_SKIP_INITIAL_VERIFY=1) =="
fi

cd "$LLC"
sudo docker stop llamacpp-server llamacpp-server-111-grev27-pool llamacpp-server-111-grev35 llamacpp-server-148-grev27-pool 2>/dev/null || true
sudo docker rm -f llamacpp-server llamacpp-server-111-grev27-pool llamacpp-server-111-grev35 llamacpp-server-148-grev27-pool 2>/dev/null || true

# shellcheck disable=SC1090
source "$LLC/.env.rpc"
# Slot cache path comes from .env.rpc (SSD fast tier by default). Only fall back
# to the HDD clone if an older .env.rpc predates SLOT_CACHE_DIR.
sudo mkdir -p "${SLOT_CACHE_DIR:-$LLC/slot-cache-111}"
LOAD_TIMEOUT="${LOAD_TIMEOUT:-1800}"

echo "== GREV80: start 80B pool CPU coordinator on hub :31360 =="
COMPOSE_COORD_PROJECT="${ALFA_RPC_COORD_COMPOSE_PROJECT:-alfa-grev27-coord}"
LORA_COMPOSE=()
if [[ -n "${LORA_GGUF:-}" ]]; then
  LORA_COMPOSE=(-f docker-compose.rpc-main.lora-volumes.yml)
  echo "== LoRA enabled: ${LORA_GGUF} (scale=${LORA_SCALE:-1.0}) =="
fi
sudo docker compose -p "$COMPOSE_COORD_PROJECT" --env-file .env.rpc \
  -f docker-compose.rpc-main.yml \
  -f docker-compose.rpc-main.cpu-coordinator.yml \
  -f docker-compose.rpc-main.grev27-pool-coordinator.yml \
  -f docker-compose.rpc-main.grev27-pool-coordinator-111-cpu.yml \
  -f docker-compose.rpc-main.grev27-load.yml \
  "${LORA_COMPOSE[@]}" \
  up -d --no-build --force-recreate

bash "$COMMON/wait-llamacpp-coordinator-health.sh" "http://127.0.0.1:${MAIN_PORT:-31360}/health" "$LOAD_TIMEOUT"

expect_ctx="${CTX_SIZE:-86016}"
props_json="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${LLAMA_API_KEY:-change-me}" \
  "http://127.0.0.1:${MAIN_PORT:-31360}/props" || true)"
got_ctx="$(printf '%s' "$props_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("default_generation_settings",{}).get("n_ctx",""))' 2>/dev/null || true)"
if [[ -n "$got_ctx" && "$got_ctx" != "$expect_ctx" ]]; then
  echo "WARN: GREV80 n_ctx=$got_ctx expected CTX_SIZE=$expect_ctx (continue; check /props)" >&2
else
  echo "== GREV80: /props n_ctx=${got_ctx:-unknown} (expect $expect_ctx) =="
fi

if [[ "${inference_SKIP_SELFTEST:-0}" != "1" ]]; then
  bash "$COMMON/selftest-grev27-coordinator.sh" \
    "http://127.0.0.1:${MAIN_PORT:-31360}" \
    "${LLAMA_API_KEY:-change-me}" \
    "${MODEL_ALIAS:-qwen3-coder-next-80b-a3b}" \
    "${GREV80_SELFTEST_TIMEOUT:-300}"
fi
echo "GREV80 pool coordinator OK. LiteLLM frontier-code -> http://127.0.0.1:31360/v1"
