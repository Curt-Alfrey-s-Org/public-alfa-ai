#!/usr/bin/env bash
# Deploy exclusive Qwen2.5-72B RPC coordinator on hub (:31360).
#
# Prerequisites:
#   - Full-mesh shards in inference_SHARDS_FILE (core + gaming + secondary + pool-opt-in)
#   - Hub GGUF lead: qwen2.5-72b-instruct-q5_k_m-00001-of-00014.gguf (+ siblings; pull gguf72)
#
# Usage (on hub):
#   sudo bash deploy/cluster-members/hub/deploy-grev72-pool-coordinator.sh
#
# Docs: docs/GREV72_72B_OPERATOR.md
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

sudo inference_SHARDS_FILE="$inference_SHARDS_FILE" bash "$SCRIPT_DIR/write-grev72-pool-env.sh"

sudo FORCE_HUB_RPC_LOAD="${FORCE_HUB_RPC_LOAD:-}" bash "$COMMON/load-llamacpp-rpc-from-hub.sh"

if [[ "${inference_SKIP_INITIAL_VERIFY:-0}" != "1" ]]; then
  echo "== GREV72: verify RPC shards ($inference_SHARDS_FILE) =="
  inference_VERIFY_RETRIES="${inference_VERIFY_RETRIES:-30}" bash "$COMMON/verify-inference-shards.sh" "$inference_SHARDS_FILE"
else
  echo "== GREV72: skip initial shard verify (inference_SKIP_INITIAL_VERIFY=1) =="
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

echo "== GREV72: start 72B pool CPU coordinator on hub :31360 =="
COMPOSE_COORD_PROJECT="${ALFA_RPC_COORD_COMPOSE_PROJECT:-alfa-grev27-coord}"
COMPOSE_YARN=()
if [[ -n "${ROPE_SCALING_TYPE:-}" ]]; then
  COMPOSE_YARN=(-f docker-compose.rpc-main.grev72-yarn.yml)
  echo "== GREV72: enabling YaRN overlay (ROPE_SCALE=${ROPE_SCALE:-?}) =="
fi
sudo docker compose -p "$COMPOSE_COORD_PROJECT" --env-file .env.rpc \
  -f docker-compose.rpc-main.yml \
  -f docker-compose.rpc-main.cpu-coordinator.yml \
  -f docker-compose.rpc-main.grev27-pool-coordinator.yml \
  -f docker-compose.rpc-main.grev27-pool-coordinator-111-cpu.yml \
  -f docker-compose.rpc-main.grev27-load.yml \
  "${COMPOSE_YARN[@]}" \
  up -d --no-build --force-recreate

bash "$COMMON/wait-llamacpp-coordinator-health.sh" "http://127.0.0.1:${MAIN_PORT:-31360}/health" "$LOAD_TIMEOUT"

# Fail loud if YaRN did not stick (runtime n_ctx must match CTX_SIZE from .env.rpc).
if [[ -n "${ROPE_SCALING_TYPE:-}" ]]; then
  expect_ctx="${CTX_SIZE:-86016}"
  props_json="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${LLAMA_API_KEY:-change-me}" \
    "http://127.0.0.1:${MAIN_PORT:-31360}/props" || true)"
  got_ctx="$(printf '%s' "$props_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("default_generation_settings",{}).get("n_ctx",""))' 2>/dev/null || true)"
  if [[ -z "$got_ctx" ]]; then
    echo "ERROR: GREV72 could not read n_ctx from /props after YaRN start" >&2
    exit 1
  fi
  if [[ "$got_ctx" != "$expect_ctx" ]]; then
    echo "ERROR: GREV72 n_ctx=$got_ctx but CTX_SIZE=$expect_ctx (server capped to GGUF train ctx?). Need YaRN argv + --override-kv qwen2.context_length (llama.cpp #17459)." >&2
    exit 1
  fi
  echo "== GREV72: /props n_ctx=$got_ctx OK (matches CTX_SIZE) =="
fi

if [[ "${inference_SKIP_SELFTEST:-0}" != "1" ]]; then
  bash "$COMMON/selftest-grev27-coordinator.sh" \
    "http://127.0.0.1:${MAIN_PORT:-31360}" \
    "${LLAMA_API_KEY:-change-me}" \
    "${MODEL_ALIAS:-qwen2.5-72b}" \
    "${GREV72_SELFTEST_TIMEOUT:-300}"
fi
echo "GREV72 pool coordinator OK. LiteLLM frontier -> http://127.0.0.1:31360/v1"
