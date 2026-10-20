#!/usr/bin/env bash
# Smoke-test LiteLLM tier routing (ROADMAP "Near-term execution order" item 1;
# same matrix as docs/DISTRIBUTED_AI.md § Step 4).
#
# Usage:
#   export LITELLM_MASTER_KEY=sk-...
#   ./scripts/smoke-litellm-tiers.sh
#
# Optional:
#   SMOKE_LITELLM_BASE_URL / LITELLM_SMOKE_BASE_URL — explicit URL for host-side curl (wins).
#   deploy/.env often sets LITELLM_BASE_URL=http://alfa-ai-litellm:4000 (Docker DNS only).
#   This script then falls back to SMOKE_LITELLM_DEFAULT or
#   http://${SMOKE_LITELLM_BRAIN_IP:-hub}:${PORT} where PORT is
#   SMOKE_LITELLM_BRAIN_PORT, else ALFA_AI_LITELLM_HOST_PORT from deploy/.env, else 4000
#   (hub brain convention in docs; generic compose defaults to 8413 — set it in .env).
#   ./scripts/smoke-litellm-tiers.sh deploy/.env   # from repo root; strips CRLF from .env
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE=""

for arg in "$@"; do
  if [[ "$arg" != -* ]]; then
    ENV_FILE="$arg"
  fi
done

if [[ -n "$ENV_FILE" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found: $ENV_FILE" >&2
    exit 1
  fi
  set -a
  # Strip CRLF so Windows-edited .env files do not break bash (line 4: $'\r': command not found).
  # shellcheck disable=SC1090
  source <(sed 's/\r$//' "$ENV_FILE")
  set +a
fi

# Host-side curl cannot resolve Docker-only DNS (e.g. alfa-ai-litellm from deploy/.env).
# Default brain IP is hub; host port prefers explicit SMOKE_* then ALFA_AI_LITELLM_HOST_PORT
# from sourced deploy/.env (matches compose), else 4000 (hub operator docs).
SMOKE_BRAIN_IP="${SMOKE_LITELLM_BRAIN_IP:-hub}"
SMOKE_BRAIN_PORT="${SMOKE_LITELLM_BRAIN_PORT:-${ALFA_AI_LITELLM_HOST_PORT:-4000}}"
SMOKE_DEFAULT="${SMOKE_LITELLM_DEFAULT:-http://${SMOKE_BRAIN_IP}:${SMOKE_BRAIN_PORT}}"
_raw_litellm="${LITELLM_BASE_URL:-}"
if [[ -n "${SMOKE_LITELLM_BASE_URL:-}" ]]; then
  BASE="$SMOKE_LITELLM_BASE_URL"
elif [[ -n "${LITELLM_SMOKE_BASE_URL:-}" ]]; then
  BASE="$LITELLM_SMOKE_BASE_URL"
elif [[ "$_raw_litellm" == *alfa-ai-litellm* ]]; then
  BASE="$SMOKE_DEFAULT"
  echo "NOTE: LITELLM_BASE_URL is Docker-internal ($_raw_litellm); using host smoke URL: $BASE" >&2
  echo "      Set SMOKE_LITELLM_BASE_URL=... if LiteLLM is published elsewhere." >&2
else
  BASE="${_raw_litellm:-$SMOKE_DEFAULT}"
fi

KEY="${LITELLM_MASTER_KEY:-}"

if [[ -z "$KEY" ]]; then
  echo "ERROR: LITELLM_MASTER_KEY is not set (export it or pass a deploy .env as first arg)." >&2
  exit 1
fi

hdr=(-H "Authorization: Bearer ${KEY}" -H "Content-Type: application/json")

pass=0
fail=0

run_tier() {
  local name="$1"
  local timeout="$2"
  local json="$3"
  echo ""
  echo "== ${name} (curl --max-time ${timeout}s) =="
  if curl -fsS --max-time "$timeout" "${BASE}/v1/chat/completions" "${hdr[@]}" -d "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    msg = (d.get("choices") or [{}])[0].get("message", {}).get("content", "")
    print("ok: first reply chars:", repr(msg[:120]))
except Exception as e:
    print("parse_error:", e)
    sys.exit(1)
'; then
    pass=$((pass + 1))
  else
    echo "FAIL: $name" >&2
    fail=$((fail + 1))
  fi
}

run_embed() {
  local timeout="${1:-90}"
  local json='{"model":"embed","input":"hello smoke"}'
  echo ""
  echo "== embeddings (curl --max-time ${timeout}s) =="
  if curl -fsS --max-time "$timeout" "${BASE}/v1/embeddings" "${hdr[@]}" -d "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
vec = (d.get("data") or [{}])[0].get("embedding")
if not vec:
    sys.exit(1)
print("ok: embedding dim", len(vec))
'; then
    pass=$((pass + 1))
  else
    echo "FAIL: embeddings" >&2
    fail=$((fail + 1))
  fi
}

echo "LiteLLM tier smoke"
echo "  base: ${BASE}"
echo "  from: ${ROOT_DIR}"

echo ""
echo "== liveliness (no auth) =="
if ! curl -fsS --max-time 15 "${BASE}/health/liveliness" >/dev/null 2>&1; then
  echo "ERROR: cannot reach ${BASE}/health/liveliness (curl connection failed)." >&2
  echo "  This machine must reach the LiteLLM listener (same LAN/VPN as the brain)." >&2
  echo "  On the cluster brain (hub), confirm LiteLLM is up and the host port is published on the LAN" >&2
  echo "  (after docker-compose.yml fix: not loopback-only). Recreate: docker compose up -d alfa-ai-litellm" >&2
  echo "  From here, try: curl -v --max-time 5 ${BASE}/health/liveliness" >&2
  echo "  Override: export SMOKE_LITELLM_BASE_URL=http://<host>:<published-port>" >&2
  echo "            (or SMOKE_LITELLM_DEFAULT to change the hub fallback when .env uses alfa-ai-litellm)" >&2
  exit 2
fi
echo "ok"

# Short completions to keep wall-clock predictable; enough to prove routing.
run_tier "tier0 inline" 120 '{"model":"inline","max_tokens":32,"temperature":0,"messages":[{"role":"user","content":"Say only: ok"}]}'
run_tier "tier1 chat" 120 '{"model":"chat","max_tokens":32,"temperature":0,"messages":[{"role":"user","content":"Say only: ok"}]}'
run_tier "tier2 agent" 180 '{"model":"agent","max_tokens":48,"temperature":0,"messages":[{"role":"user","content":"One-line Python: print(1)"}]}'
run_tier "tier3a frontier (Petals)" 600 '{"model":"frontier","max_tokens":64,"temperature":0,"messages":[{"role":"user","content":"One sentence on pipeline parallelism."}]}'
run_tier "tier3b frontier-code (llama.cpp RPC)" 600 '{"model":"frontier-code","max_tokens":64,"temperature":0,"messages":[{"role":"user","content":"One line: def add(a,b): return a+b"}]}'
run_embed 90

echo ""
echo "----"
echo "PASS: $pass  FAIL: $fail"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
