# inference throughput benchmarks (27B RPC pool)

Record **decode tok/s** (streaming response speed) for LiteLLM alias `qwen3.6-27b`
after all GPU shards in [`deploy/llamacpp-rpc/inference-shards.env`](../deploy/llamacpp-rpc/inference-shards.env)
pass TCP preflight.

**Decode tok/s** = `completion_tokens / (total_time - ttft)` using OpenAI streaming
with `stream_options.include_usage` ([OpenAI streaming cookbook](https://developers.openai.com/cookbook/examples/how_to_stream_completions)).

**Wall tok/s** = `completion_tokens / total_time` (includes prefill; misleading on long prompts).

## Prerequisites

1. `bash deploy/cluster-members/_common/verify-inference-shards.sh` -- all OK
2. `curl -fsS http://hub/health` -- 200 (not 503 Loading model)
3. Brain on `hub` using inference config (`LITELLM_CONFIG=litellm_config.inference.yaml`)

## Run benchmark

**From `inference`** (NFS `/mnt/cluster` mounted) or any host with brain `.env`:

```bash
cd ~/alfa-ai   # or /home/operator/alfa-ai
BENCH_WARMUP=1 BENCH_MODE=both bash scripts/benchmark-inference-litellm.sh
```

- `BENCH_MODE=short` -- small prompt, 64 completion tokens (default)
- `BENCH_MODE=long` -- ~8k-char prompt (prefill / `--batch-size`)
- `BENCH_MODE=both` -- short then long
- `BENCH_WARMUP=1` -- discard one minimal completion before timed runs (skip cold load)

Optional: `LITELLM_BASE=http://hub bash scripts/benchmark-inference-litellm.sh`

**Canonical:** run from **`inference`** over LAN (matches consumer bots). Running on **`hub`
localhost is fine for smoke; if decode shows `n/a` or absurd tok/s, LiteLLM Redis cache
or sub-50ms timing fooled the meter — the script now sends `cache: {no-cache, no-store}`
and a unique prompt nonce ([LiteLLM caching](https://docs.litellm.ai/docs/proxy/caching)).

Example output:

```text
short: ... decode=8.12 tok/s wall=6.58 tok/s total=9.7s
== summary (decode tok/s = real response speed; wall includes prefill) ==
label      prompt    comp   ttft   decode     wall   total
short           12     64  0.45s    8.12/s    6.58/s    9.7s
```

A/B without 1660S, LAG, MTP: [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md).

## Target

With **five GPU shards** loaded, expect **decode tok/s well above 1** on a 1 GbE LAN
for the short prompt. Partial pools often sit near **~1 tok/s or lower**.

Official references:

- [llama.cpp multi-gpu](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md)
- [llama.cpp RPC](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)
- [OpenAI streaming + usage](https://developers.openai.com/cookbook/examples/how_to_stream_completions)

## Results log

| Date | Operator | Shards OK | Model alias | Decode tok/s | Notes |
|------|----------|-----------|-------------|--------------|-------|
| 2026-08-17 | operator | inference full opt-in mesh; alias still `qwen3.6-27b` | Qwen3.8-27B Q8 (**production flip**) | SPA decode **~4.4 tok/s** after **191.6 s** TTFT on Instruct "reply with pong" | Coordinator probe: 15 prompt tokens in **101 s** prefill (`prompt_ms`), then ~3.4 tok/s. Hybrid Gated DeltaNet + RPC mesh; not a downed pool. Prior row was inference_38 test cycle. |
| 2026-07-10 | operator / agent | 5-shard; `/props` **total_slots=10** n_ctx=16384; `CTX=163840` | qwen3.6-27b | **short decode 8.22** / **long decode 8.32** tok/s (wall short 5.56, long 0.56) | `BENCH_WARMUP=1 BENCH_MODE=both` streaming from `inference`. TTFT short 3.7s / long 18.2s. Commit `b12f8d5`. |
| 2026-07-10 | operator / agent | 5-shard inference; `/props` **total_slots=6** n_ctx=32768; `CTX=196608` `-b 4096` | qwen3.6-27b | **short wall 6.62** (legacy wall metric) | `inference_SKIP_VERIFY=1 BENCH_MODE=both` from `inference`. |
| 2026-06-29 | ansible | 111:31353, 148:31356, 93:31350 | frontier-code (qwen3.6-27b) | 0.29 cold / 405 warm wall | Cold: 64 tok in 218.6s (RPC model load). Warm: 64 tok in 0.2s. |

## Cold start (first request after idle or coordinator restart)

Measured on this cluster (2026-06-29 and 2026-08-06):

| Phase | Typical duration | What you see |
|-------|------------------|--------------|
| Coordinator `/health` not ready | ~2 min | `connection refused` or **503 Loading model** ([llama-server health](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)) |
| First full chat completion (cold weights) | **~3-4 min** | Single benchmark: 218s for 64 tokens (load + generate) |
| **Short "hi" TTFT on live pool (2026-08-06)** | **often ~80-95 s** | Brain SPA `first ~92s` then `~3.5 tok/s`; **not** Qwen thinking (same delay with `enable_thinking: false`) |
| **Qwen3.8 Instruct "pong" (2026-08-17, production)** | **~190-200 s TTFT** | Same RPC mesh; SPA `199.2s - first 191.6s - ~4.4 tok/s`. Accepted for production flip. Follow-up on a long prior thread times out (full-history prefill). Historical 3.6 core-only short TTFT was **~3.7 s** (2026-07-10). |
| Occasional warm short TTFT | **~1-4 s** | Same coordinator; intermittent -- not reliable after one keep-warm ping |

Production coordinator: **`--no-warmup`**, **`PARALLEL=5`** (`total_slots=5` on `/props`).
Historical warm short TTFT was **~3.7 s** decode **~8 tok/s** (2026-07-10, smaller shard set).
After expanding gaming + `secondary` + `pool-opt-in` shards, decode dropped to **~3.5 tok/s** and
short-prompt TTFT is frequently **~90 s** even on sequential requests -- this points at
**RPC prefill / mesh cost**, not the SPA "thinking" indicator.

`keep-inference-warm.sh` now sends **`inference_WARM_SLOTS` concurrent streaming** pings
(default **5**) so unused slots are not left cold. That is necessary but **not sufficient**
alone when every new prompt still pays ~90 s.

**Operator rule:** after full cluster start, run multi-slot `keep-inference-warm.sh`, then
smoke a short chat. If `first` stays ~90 s, treat as pool perf (shard count / RPC), not
a UI bug. Latency experiment: start with gaming/`secondary`/`pool-opt-in` opted out and re-measure TTFT
against the four-host core set ([CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md)).

## Keep warm (recommended on `hub` brain)

`scripts/keep-inference-warm.sh` sends **`inference_WARM_SLOTS` concurrent streaming** minimal
`qwen3.6-27b` completions (default **5**, matching `PARALLEL`) every 15 minutes so each
slot gets a first-use pass. Cron runs on **`hub`** with
`inference_WARM_LITELLM_BASE=http://127.0.0.1:8413` (no LAN hop to LiteLLM). Orchestrator
shard verify runs from **`inference`** hub.

**Install cron on `hub` (operator):**

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash deploy/cluster-members/hub/operator-cluster-111.sh install-keep-warm
```

**Retire legacy `apps` cron:**

```bash
cd ~/alfa-ai
bash scripts/install-inference-keep-warm-cron.sh --uninstall-only
```

**Manual run on `hub`:**

```bash
inference_WARM_LITELLM_BASE=http://127.0.0.1:8413 inference_WARM_CONTRACTS_BOT=0 bash scripts/keep-inference-warm.sh
```

**Diagnostics** (shards flapping / degraded UI):

```bash
bash scripts/diagnose-inference-ai.sh
curl -fsS http://127.0.0.1:8002/api/health/connectivity   # on apps
```

If any shard TCP fails, redeploy that host's `deploy-grev27-pool-shard` before warm ping or scans.
Coordinator `/health` can stay **200** while GPU shards are down -- always verify `verify-inference-shards.sh`.
