#!/usr/bin/env bash
# Real-world LiteLLM benchmark for 27B inference (streaming decode tok/s).
#
# Usage (from inference with /mnt/cluster mounted, or any host with brain .env):
#   bash scripts/benchmark-inference-litellm.sh
#   BENCH_MODE=both bash scripts/benchmark-inference-litellm.sh
#   BENCH_WARMUP=1 BENCH_MODE=both bash scripts/benchmark-inference-litellm.sh
#
# BENCH_MODE:
#   short  -- small prompt, max_tokens=64 (default)
#   long   -- ~8k-char prompt, max_tokens=128 (prefill stress)
#   both   -- short then long
#
# Metrics (streaming + stream_options.include_usage per OpenAI API):
#   decode tok/s = completion_tokens / (last_token_time - ttft)  -- response generation rate
#   wall tok/s   = completion_tokens / total_sec               -- end-to-end (includes prefill)
#   ttft         = time to first content token (prefill latency)
#
# Requests set cache no-cache + no-store (LiteLLM proxy caching docs) and a unique
# prompt nonce so Redis cache cannot return instant fake tok/s.
# Canonical run: from inference over LAN (http://hub). Localhost on hub is OK
# for smoke but LAN path matches real consumer bots.
#
# Log results in docs/inference_BENCHMARKS.md. For 1660S A/B see docs/inference_PERF_AND_SHARDS.md.
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

BASE="${LITELLM_BASE:-http://hub}"
KEY="${LITELLM_MASTER_KEY:-}"
if [[ -z "$KEY" ]]; then
  echo "ERROR: LITELLM_MASTER_KEY unset in $ENV_FILE" >&2
  exit 1
fi

BENCH_MODE="${BENCH_MODE:-short}"
BENCH_WARMUP="${BENCH_WARMUP:-0}"

echo "== inference benchmark: LiteLLM at ${BASE} mode=${BENCH_MODE} (streaming decode tok/s) =="
echo "== preflight: verify inference shards (optional skip with inference_SKIP_VERIFY=1) =="
if [[ "${inference_SKIP_VERIFY:-0}" != "1" ]]; then
  inference_VERIFY_RETRIES="${inference_VERIFY_RETRIES:-15}" \
    bash "$REPO_DIR/deploy/cluster-members/_common/verify-inference-shards.sh" || {
    echo "WARN: shard TCP preflight failed; benchmark may reflect partial pool" >&2
  }
fi

export BASE KEY REPO_DIR BENCH_MODE BENCH_WARMUP
python3 <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

base = os.environ["BASE"].rstrip("/")
key = os.environ["KEY"]
mode = os.environ.get("BENCH_MODE", "short").lower()
warmup = os.environ.get("BENCH_WARMUP", "0") == "1"
model = "qwen3.6-27b"
MIN_DECODE_SEC = 0.05  # sub-50ms decode window is not measurable (cache / timer noise)


def long_prompt(nonce: int) -> str:
    unit = (
        "Section: summarize the following inventory line for an operator brief. "
        "Host GPU VRAM free MiB tensor-split RPC port context slots. "
    )
    return (
        (unit * 80)
        + f"\n\nTask: Reply with exactly one sentence: OK long-prefill. [bench-{nonce}]"
    )


def stream_completion(prompt: str, max_tokens: int) -> dict:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
        # https://docs.litellm.ai/docs/proxy/caching — bypass Redis response cache for benchmarks
        "cache": {"no-cache": True, "no-store": True},
    }
    raw = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        f"{base}/v1/chat/completions",
        data=raw,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        },
        method="POST",
    )
    t0 = time.perf_counter()
    ttft: float | None = None
    t_last_content: float | None = None
    text_parts: list[str] = []
    usage: dict = {}
    cache_key: str | None = None
    try:
        with urllib.request.urlopen(req, timeout=1200) as resp:
            cache_key = resp.headers.get("x-litellm-cache-key")
            while True:
                line = resp.readline()
                if not line:
                    break
                line = line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                if chunk.get("usage"):
                    usage = chunk["usage"]
                choices = chunk.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                content = delta.get("content")
                if content:
                    now = time.perf_counter()
                    if ttft is None:
                        ttft = now - t0
                    t_last_content = now
                    text_parts.append(content)
    except urllib.error.HTTPError as exc:
        elapsed = time.perf_counter() - t0
        err_body = exc.read().decode("utf-8", errors="replace")[:400]
        raise RuntimeError(f"HTTP {exc.code} in {elapsed:.3f}s: {err_body}") from exc

    total = time.perf_counter() - t0
    if ttft is None:
        ttft = total
    if t_last_content is None:
        t_last_content = t0 + ttft
    prompt_tok = int(usage.get("prompt_tokens") or 0)
    comp_tok = int(usage.get("completion_tokens") or 0)
    decode_sec = max(t_last_content - (t0 + ttft), 1e-9)
    decode_reliable = decode_sec >= MIN_DECODE_SEC and total >= MIN_DECODE_SEC
    decode_tok_s = comp_tok / decode_sec if comp_tok and decode_reliable else 0.0
    wall_tok_s = comp_tok / total if total > 0 and comp_tok else 0.0
    prefill_tok_s = prompt_tok / ttft if ttft > 0 and prompt_tok else 0.0
    return {
        "prompt_tokens": prompt_tok,
        "completion_tokens": comp_tok,
        "total_sec": total,
        "ttft_sec": ttft,
        "decode_sec": decode_sec,
        "decode_tok_s": decode_tok_s,
        "decode_reliable": decode_reliable,
        "wall_tok_s": wall_tok_s,
        "prefill_tok_s": prefill_tok_s,
        "cache_key": cache_key,
        "sample": "".join(text_parts)[:120],
    }


def warmup_ping(nonce: int) -> None:
    print("warmup: minimal completion (discarded)...")
    stream_completion(f"Reply with exactly: OK [bench-warm-{nonce}]", 4)
    print("warmup: done")


cases: list[tuple[str, str, int]] = []
bench_nonce = int(time.time() * 1000)
if mode in ("short", "both"):
    cases.append(
        (
            "short",
            f"Count from 1 to 20 with commas, no other text. [bench-{bench_nonce}]",
            64,
        )
    )
if mode in ("long", "both"):
    cases.append(("long", long_prompt(bench_nonce), 128))
if not cases:
    print(f"ERROR: unknown BENCH_MODE={mode!r} (use short|long|both)")
    raise SystemExit(2)

if warmup:
    warmup_ping(bench_nonce)

rows: list[tuple[str, dict]] = []
for label, prompt, max_tokens in cases:
    try:
        result = stream_completion(prompt, max_tokens)
    except Exception as exc:
        print(f"{label}: ERROR {exc}")
        raise SystemExit(1) from exc
    rows.append((label, result))
    decode_label = (
        f"{result['decode_tok_s']:.2f} tok/s"
        if result["decode_reliable"]
        else "n/a (too fast; likely cache/timer)"
    )
    print(
        f"{label}: prompt_tokens={result['prompt_tokens']} "
        f"completion_tokens={result['completion_tokens']} "
        f"ttft={result['ttft_sec']:.3f}s "
        f"decode={decode_label} "
        f"wall={result['wall_tok_s']:.2f} tok/s "
        f"total={result['total_sec']:.3f}s"
    )
    if result["prompt_tokens"] > 500:
        print(f"  prefill={result['prefill_tok_s']:.1f} prompt tok/s")
    print(f"  sample: {result['sample'].replace(chr(10), ' ')[:80]}")
    if not result["decode_reliable"]:
        print(
            "  NOTE: decode rate unreliable on this run (sub-50ms or LiteLLM cache). "
            "Use wall tok/s or re-run from inference over LAN."
        )
    elif result["decode_tok_s"] <= 1.0:
        print("  NOTE: decode <= 1 tok/s often means missing GPU shards or CPU-only coordinator")

    repo = os.environ.get("REPO_DIR", "")
    if repo and result["completion_tokens"] and result["total_sec"] > 0:
        try:
            sys.path.insert(0, repo)
            from src.api.inference_pool_stats import record_inference_probe

            probe_decode = result["decode_tok_s"] if result["decode_reliable"] else None
            record_inference_probe(
                source=f"benchmark-inference-{label}",
                model=model,
                completion_tokens=int(result["completion_tokens"]),
                elapsed_sec=result["total_sec"],
                pool="inference",
                decode_tok_per_sec=probe_decode,
                ttft_sec=result["ttft_sec"],
            )
        except Exception:
            pass

print("")
print("== summary (decode tok/s = real response speed; wall includes prefill) ==")
print(f"{'label':<8} {'prompt':>7} {'comp':>5} {'ttft':>6} {'decode':>8} {'wall':>8} {'total':>7}")
for label, r in rows:
    dec = f"{r['decode_tok_s']:>7.2f}/s" if r["decode_reliable"] else "     n/a"
    print(
        f"{label:<8} {r['prompt_tokens']:>7} {r['completion_tokens']:>5} "
        f"{r['ttft_sec']:>5.3f}s {dec} "
        f"{r['wall_tok_s']:>7.2f}/s {r['total_sec']:>6.3f}s"
    )

print("== Log this run in docs/inference_BENCHMARKS.md (use decode tok/s column) ==")
PY
