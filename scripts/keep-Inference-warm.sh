#!/usr/bin/env bash
# Keep inference model loaded via minimal LiteLLM completions (all parallel slots).
#
# Canonical cron host: hub brain (localhost LiteLLM). Orchestrator post-start also
# runs this script. Legacy apps cron is deprecated - use
# deploy/cluster-members/hub/install-inference-keep-warm-cron.sh on hub.
#
# Sends inference_WARM_SLOTS concurrent *streaming* completions (default 5 = PARALLEL)
# so unused slots get a first-use pass. Does not by itself fix ~90s TTFT when the
# expanded RPC mesh is slow on short prompts - see docs/inference_BENCHMARKS.md.
#
# Usage:
#   bash scripts/keep-inference-warm.sh
#   inference_WARM_LITELLM_BASE=http://127.0.0.1:8413  # hub cron (recommended)
#   inference_WARM_SLOTS=5                             # match coordinator PARALLEL
#   inference_WARM_CONTRACTS_BOT=0                     # skip contracts-bot warm marker
#   inference_WARM_CONTRACTS_BOT_URL=http://apps  # default when not local
#   inference_WARM_CONTRACTS_BOT_CONNECT_TIMEOUT_SEC=4 # fast-fail when app absent (no long stall)
#
# Cron (hub): bash deploy/cluster-members/hub/install-inference-keep-warm-cron.sh
# Docs: docs/inference_BENCHMARKS.md (cold start / keep warm)
# Official: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ALFA_BRAIN_ENV:-/mnt/cluster/repo/alfa-ai/deploy/.env}"
if [[ ! -f "$ENV_FILE" && -f "$REPO_DIR/deploy/.env" ]]; then
  ENV_FILE="$REPO_DIR/deploy/.env"
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: brain deploy/.env not found (set ALFA_BRAIN_ENV)" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

BASE="${inference_WARM_LITELLM_BASE:-${LITELLM_BASE:-http://hub}}"
# Host-side warm on hub: compose env often uses Docker DNS (alfa-ai-litellm:4000).
if [[ "$BASE" == *alfa-ai-litellm* ]]; then
  BASE="http://127.0.0.1:${ALFA_AI_LITELLM_HOST_PORT:-8413}"
fi
KEY="${LITELLM_MASTER_KEY:-}"
MODEL="${inference_WARM_MODEL:-qwen3.6-27b}"
# Parallel cold slot warm can take ~90s wall; allow headroom for all slots.
TIMEOUT="${inference_WARM_TIMEOUT_SEC:-300}"
# Match deploy/llamacpp-rpc inference PARALLEL (coordinator total_slots).
WARM_SLOTS="${inference_WARM_SLOTS:-5}"
SKIP_VERIFY="${inference_SKIP_VERIFY:-0}"

if [[ -z "$KEY" ]]; then
  echo "ERROR: LITELLM_MASTER_KEY unset in $ENV_FILE" >&2
  exit 1
fi

if [[ "$SKIP_VERIFY" != "1" ]]; then
  if ! bash "$REPO_DIR/deploy/cluster-members/_common/verify-inference-shards.sh"; then
    echo "WARN: inference shard preflight failed; skip warm ping" >&2
    exit 0
  fi
fi

export BASE KEY MODEL TIMEOUT WARM_SLOTS REPO_DIR
python3 <<'PY'
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import httpx

base = os.environ["BASE"].rstrip("/")
key = os.environ["KEY"]
model = os.environ["MODEL"]
timeout = float(os.environ["TIMEOUT"])
try:
    n_slots = max(1, int((os.environ.get("WARM_SLOTS") or "5").strip()))
except ValueError:
    n_slots = 5

headers = {"Authorization": f"Bearer {key}"}


def warm_one(slot_idx: int) -> tuple[int, float, int, int, str]:
    """Return (slot_idx, elapsed_sec, http_status, completion_tokens, err)."""
    t0 = time.perf_counter()
    # Distinct prompts so concurrent requests claim distinct slots.
    # Stream: concurrent non-stream can hang on cold multi-slot RPC; streaming
    # completed in ~90s wall in cluster A/B (2026-08-06).
    body = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": f"Reply with exactly: OK{slot_idx}",
            }
        ],
        "max_tokens": 4,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    try:
        with httpx.stream(
            "POST",
            f"{base}/v1/chat/completions",
            headers=headers,
            json=body,
            timeout=timeout,
        ) as r:
            status = r.status_code
            if status != 200:
                err_body = r.read().decode("utf-8", errors="replace")[:200]
                return slot_idx, time.perf_counter() - t0, status, 0, err_body
            comp = 0
            got_delta = False
            for line in r.iter_lines():
                if not line:
                    continue
                if not line.startswith("data: "):
                    continue
                raw = line[6:].strip()
                if raw == "[DONE]":
                    break
                try:
                    obj = json.loads(raw)
                except Exception:
                    continue
                usage = obj.get("usage") or {}
                if usage.get("completion_tokens") is not None:
                    comp = int(usage.get("completion_tokens") or 0)
                choices = obj.get("choices") or []
                if choices:
                    delta = (choices[0].get("delta") or {}).get("content") or ""
                    if delta:
                        got_delta = True
            elapsed = time.perf_counter() - t0
            if not got_delta and comp <= 0:
                return (
                    slot_idx,
                    elapsed,
                    status,
                    0,
                    "stream finished with no content deltas",
                )
            return slot_idx, elapsed, status, max(comp, 1 if got_delta else 0), ""
    except Exception as exc:
        return slot_idx, time.perf_counter() - t0, 0, 0, str(exc)


t0 = time.perf_counter()
results = []
with ThreadPoolExecutor(max_workers=n_slots) as pool:
    futs = [pool.submit(warm_one, i) for i in range(n_slots)]
    for fut in as_completed(futs):
        results.append(fut.result())
elapsed = time.perf_counter() - t0

results.sort(key=lambda row: row[0])
failed = [row for row in results if row[2] != 200 or row[4]]
for slot_idx, slot_elapsed, status, comp, err in results:
    if err and status == 0:
        print(f"inference-warm slot={slot_idx} ERROR after {slot_elapsed:.1f}s: {err}")
    elif status != 200:
        print(f"inference-warm slot={slot_idx} HTTP {status} in {slot_elapsed:.1f}s: {err}")
    else:
        print(
            f"inference-warm slot={slot_idx} OK model={model} tokens={comp} "
            f"elapsed={slot_elapsed:.1f}s"
        )

if failed:
    print(f"inference-warm FAIL slots={n_slots} wall={elapsed:.1f}s failed={len(failed)}")
    sys.exit(1)

total_comp = sum(row[3] for row in results)
print(
    f"inference-warm OK model={model} slots={n_slots} tokens={total_comp} "
    f"wall={elapsed:.1f}s"
)

repo = os.environ.get("REPO_DIR", "")
if repo and total_comp and elapsed > 0:
    try:
        sys.path.insert(0, repo)
        from src.api.inference_pool_stats import record_inference_probe

        record_inference_probe(
            source="inference-warm",
            model=model,
            completion_tokens=int(total_comp),
            elapsed_sec=elapsed,
            pool="inference",
        )
    except Exception:
        pass
PY

# Mark contracts-bot UI ready: in-process chat probe via API worker (not docker exec).
if [[ "${inference_WARM_CONTRACTS_BOT:-1}" == "1" ]]; then
  CB_URL="${inference_WARM_CONTRACTS_BOT_URL:-}"
  if [[ -z "$CB_URL" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'contracts-bot-api'; then
    CB_PORT="${CONTRACTS_BOT_API_PORT:-8002}"
    CB_URL="http://127.0.0.1:${CB_PORT}"
  fi
  if [[ -z "$CB_URL" ]]; then
    CB_URL="${inference_WARM_CONTRACTS_BOT_URL_DEFAULT:-http://apps}"
  fi
  CB_TIMEOUT="${inference_WARM_CONTRACTS_BOT_TIMEOUT_SEC:-180}"
  # Fast-fail when contracts-bot is not reachable (separate stack; often not on
  # this host). Bound the TCP connect so an absent app cannot stall the whole
  # keep-warm phase for minutes (was observed hanging 133s on apps:8002).
  CB_CONNECT_TIMEOUT="${inference_WARM_CONTRACTS_BOT_CONNECT_TIMEOUT_SEC:-4}"
  if curl -fsS --connect-timeout "$CB_CONNECT_TIMEOUT" --max-time "$CB_TIMEOUT" "${CB_URL%/}/api/health/connectivity?warm=1" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ready = bool((data.get('alfa_ai') or {}).get('contract_ai_ready'))
print('contracts-bot warm: contract_ai_ready=%s url=%s' % (ready, sys.argv[1]), file=sys.stderr)
sys.exit(0 if ready else 1)
" "$CB_URL"; then
    echo "contracts-bot warm OK (${CB_URL})"
  else
    echo "WARN: contracts-bot warm probe failed (${CB_URL})" >&2
  fi
fi
