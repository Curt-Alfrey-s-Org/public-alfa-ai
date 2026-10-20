#!/usr/bin/env bash
# Real end-to-end compute self-test for the 27B RPC pool coordinator.
#
# WHY: the coordinator's /health returns 200 as soon as the model metadata loads
# and the dry-run sched_reserve succeeds -- it does NOT prove that every rpc-server
# shard can execute a real decode. The coordinator runs with --no-warmup, so the
# FIRST real decode is the first time compute is dispatched over RPC. If a shard is
# wedged (TCP port open but compute broken), that first decode makes llama.cpp
# ggml_abort() the coordinator (SIGABRT / exit 134):
#   ggml-rpc.cpp: "Remote RPC server crashed or returned malformed response"
# A plain `nc -z` TCP check cannot detect this. This script fires ONE tiny decode
# so "green" means "compute works end-to-end", not merely "port open".
#
# Usage (on hub, after coordinator /health is OK):
#   bash deploy/cluster-members/_common/selftest-grev27-coordinator.sh \
#     [BASE_URL] [API_KEY] [MODEL] [TIMEOUT_SEC]
#
# Defaults: BASE_URL=http://127.0.0.1:31360  API_KEY=change-me
#           MODEL=(auto-detect from /v1/models)  TIMEOUT_SEC=180
#
# Exit 0 = a real completion returned. Exit 1 = compute failed (pool NOT green).
set -euo pipefail

BASE_URL="${1:-${GREV27_SELFTEST_BASE:-http://127.0.0.1:31360}}"
API_KEY="change-me"
MODEL="${3:-${GREV27_SELFTEST_MODEL:-}}"
TIMEOUT="${4:-${GREV27_SELFTEST_TIMEOUT:-180}}"
BASE_URL="${BASE_URL%/}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl not found (required for coordinator self-test)" >&2
  exit 1
fi

# Resolve the served model id if not supplied (robust to alias changes).
if [[ -z "$MODEL" ]]; then
  models_json="$(curl -fsS --max-time 15 \
    -H "Authorization: Bearer ${API_KEY}" \
    "${BASE_URL}/v1/models" 2>/dev/null || true)"
  if command -v python3 >/dev/null 2>&1 && [[ -n "$models_json" ]]; then
    MODEL="$(printf '%s' "$models_json" | python3 -c \
      'import sys,json
try:
    d=json.load(sys.stdin); print((d.get("data") or [{}])[0].get("id",""))
except Exception:
    print("")' 2>/dev/null || true)"
  fi
  MODEL="${MODEL:-qwen3.6-27b}"
fi

echo "== grev27 coordinator self-test: real decode =="
echo "  base=$BASE_URL model=$MODEL timeout=${TIMEOUT}s"

req_body="$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":4,"temperature":0}' "$MODEL")"

http_body="$(mktemp)"
trap 'rm -f "$http_body"' EXIT

t0="$(date +%s)"
http_code="$(curl -sS -o "$http_body" -w '%{http_code}' \
  --max-time "$TIMEOUT" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -X POST "${BASE_URL}/v1/chat/completions" \
  -d "$req_body" 2>/dev/null || echo 000)"
t1="$(date +%s)"
elapsed=$(( t1 - t0 ))

if [[ "$http_code" != "200" ]]; then
  echo "  FAIL self-test HTTP $http_code in ${elapsed}s" >&2
  echo "  ----- response (truncated) -----" >&2
  head -c 500 "$http_body" >&2 || true
  echo >&2
  echo "  A wedged shard (port open, compute broken) crashes the coordinator on first decode." >&2
  echo "  RECOVERY ORDER (never reconnect a fresh coordinator to a wedged shard):" >&2
  echo "    1) redeploy ALL shards in active list (inference/orchestrator/pool-opt-in + opted-in gaming + hub)" >&2
  echo "    2) redeploy the coordinator (hub :31360)" >&2
  echo "    3) re-run this self-test" >&2
  echo "  Official: /health is load-ready only (tools/server/README.md); RPC is fragile PoC" >&2
  echo "  (tools/rpc/README.md). Do not start LiteLLM before this gate on cluster start." >&2
  exit 1
fi

# Confirm the body actually contains a completion, not an error envelope.
if command -v python3 >/dev/null 2>&1; then
  ok="$(python3 -c \
    'import sys,json
try:
    d=json.load(open(sys.argv[1]))
    c=(d.get("choices") or [{}])[0].get("message",{}).get("content")
    print("1" if isinstance(c,str) else "0")
except Exception:
    print("0")' "$http_body" 2>/dev/null || echo 0)"
  if [[ "$ok" != "1" ]]; then
    echo "  FAIL self-test: HTTP 200 but no choices[].message.content" >&2
    head -c 500 "$http_body" >&2 || true
    echo >&2
    exit 1
  fi
fi

echo "  OK self-test decode returned in ${elapsed}s (pool compute verified end-to-end)"
exit 0
