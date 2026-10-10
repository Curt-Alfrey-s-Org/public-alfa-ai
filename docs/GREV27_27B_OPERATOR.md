# G-rev27 operator runbook - Qwen3.8-27B RPC pool (Phase H)

Production **default** **`frontier-code`** (and **`frontier`**): **Qwen3.8-27B Q8_0**
(non-MTP, ~29 GB) on the **4-shard always-on RPC core** (**35.0 GB** nominal
`-ts` sum: `inference` 3060+5060, `orchestrator` 3060, `hub` 3050), with **`PARALLEL=5`** /
**`CTX_SIZE=262144`** (52428 tokens/slot; **2 user + 3 automated**; Qwen3.8 native max).
**inference opt-in at each cluster start** (Y/N): **`gaming-a`**, **`gaming-c`**, **`gaming-b`**,
**`secondary`** (1070), and **`pool-opt-in`** (1660S). Never required for core green.
**`gaming-c` / `gaming-b`** overlap the **7B** train island (14B archived on hub HDD) — blocked while `alfa-train.lock`
is set. **Operator:** do not game and train or serve inference on the same GPU at
once (disk-only cache staging is OK). With **`gaming-a` + `secondary` + `pool-opt-in`**: **`TENSOR_SPLIT` ~52 GB** / **~60 GB**
physical (`12,8,5,10,7,5,5`). With **all five** opt-in: **`12,8,5,9,9,10,7,5,5`**
(**70.0 GB** nominal `-ts`). **Retired for 27B:** legacy mesh `12,9,5,9,9,11,6,4.2,2.8`.
**CPU coordinator on `hub`
`:31360`** (7900X). **Retired (do not seed or start):** **35B MoE**, **30B coder**
GGUF, **Llama-3.3-70B** (Petals), **qwen3:8b** operator chat. Production = **27B**
only. Do not run `switch-pool-35b.sh` unless the operator explicitly revives that
path. **Future `frontier`:** dense **~70–72B Q4** exclusive on the full mesh (see
[experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md](experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md)).
**Q4 multi-slot rollback:** keep `UD-Q4_K_XL` on hub; see [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md).

**Flash-Next (not inference):** **Qwen3.8-Flash-Next Q8_0** (~175 GiB, `qwen4exp`) **does not
fit** this mesh and is **not** a inference production GGUF. Do not load it or add a UI switch
until hardware changes; see [FLASH_NEXT_Q8_FIT.md](FLASH_NEXT_Q8_FIT.md). Same-slot **27B**
upgrades stay [inference_MODEL_UPGRADE.md](inference_MODEL_UPGRADE.md).

**Shard list:** `inference-shards.core.env` + opt-in `inference-shards.gaming.env` ->
gitignored `inference-shards.active.env` at start. Preview:
`bash deploy/cluster-members/_common/validate-inference-shards.sh`. Regenerate
`.env.rpc` on `hub` with `write-grev27-pool-env.sh` (honors `inference_SHARDS_FILE`).
Perf / LAG / MTP / A/B: [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md).
Gaming leave/join: [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md).
**Before Pool72/80 join on `gaming-c`/`gaming-b`:** [inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md)
(pitfalls from `gaming-a` join: VRAM reserve, SMB/vendor UNC, LAN probe, git reset).

**GPU-only on shards** (`--fit off`, `-ngl 999`) ? coordinator orchestrates via RPC only.

SSoT: [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).

**Stop on errors.** Do not proceed if the current step exits non-zero.

## Official references

| Topic | URL |
|-------|-----|
| llama.cpp RPC | https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md |
| Multi-GPU / tensor-split | https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md |
| `llama-server` flags | https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md |
| HF verify | https://huggingface.co/docs/huggingface_hub/en/guides/cli#hf-cache-verify |

## Topology (4-shard core + optional gaming hosts; coordinator on `hub`)

| Load order | Host | GPU | Port | `-ts` |
|------------|------|-----|------|-------|
| **coord** | `hub` | **CPU** | `:31360` | orchestration only |
| 1 (fastest) | `inference` | RTX 3060 | `:31356` | **12** (12288 MiB) |
| 2 | `inference` | RTX 5060 | `:31357` | **8** (8151 MiB physical -- do not set 9) |
| 2b (opt-in) | `gaming-a` | RTX 5060 | `:31352` | **5** (8 GB card - **3072 MiB** Win10/WDDM headroom) |
| 2c (opt-in) | `gaming-c` | RTX 5070 | `:31351` | **9** (12 GB minus ~3 GiB desktop reserve) |
| 2d (opt-in) | `gaming-b` | RTX 5070 | `:31358` | **9** (12 GB minus ~3 GiB desktop reserve) |
| 3 | `orchestrator` | RTX 3060 | `:31350` | **10** (12 GB minus **2048 MiB** WDDM; preflight **`MAX_MIB=4096`**) |
| 4 | gpu-248 (`secondary`) | GTX 1070 | `:31355` | **7** (8 GB minus ~1 GiB iGPU/desktop) — **opt-in** |
| 5 | VM100 (`pool-opt-in`) | GTX 1660 Super | `:31354` | **5** (6 GB minus ~1 GiB) — **opt-in** |
| 6 (slowest) | `hub` | RTX 3050 | `:31353` | **5** (nvidia-smi **6144 MiB** / 6 GB; not 4 GB) |

**Membership:** always-on lines live in `inference-shards.core.env`. Gaming hosts are
catalogued in `inference-shards.gaming.env` and **opted in at each**
`Start-Stop-AlfaAi.ps1 start` (writes gitignored `inference-shards.active.env`).
Committed `inference-shards.env` = core-only fallback. See
[CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) (gaming opt-in).

Default active list (**core only** — no opt-in hosts):

`RPC_BACKENDS=orchestrator,orchestrator,orchestrator,hub`

`TENSOR_SPLIT=12,8,10,5` (**35.0 GB**). With **`gaming-a` + `secondary` + `pool-opt-in`**
(fastest-first merge): `12,8,5,10,7,5,5` (**52.0 GB** nominal; **~60 GB**
physical). With **all five** opt-in (`gaming-a`/`gaming-c`/`gaming-b`/`secondary`/`pool-opt-in`):
`12,8,5,9,9,10,7,5,5` (**70.0 GB**). Example with only `gaming-a`: `12,8,5,10,5`.
Live mesh 2026-09-11 (`secondary`+`pool-opt-in`, no `gaming-a`): `12,8,10,7,5,5` (**47.0 GB**).
**Retired for 27B:** legacy `12,9,5,9,9,11,6,4.2,2.8`. Tail shards
carry less KV; see
[llama.cpp multi-gpu.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md)
`--tensor-split` proportions.

**Why this split (2026-09-11 `nvidia-smi`):** llama.cpp `-ts` is **normalized
proportions of the model**, not a GB cap. Official:
[multi-gpu.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md)
(`-ts 3,1` = 75/25). RPC backends do not auto-see remote VRAM, so the list must
match **usable GiB**. Prior list overweighted the `inference` 5060 (`VRAM_GB=9` on an
**8151 MiB** card) and underweighted the `hub` 3050 (`4 70` → 2.8 on a **6144 MiB**
card). That packed the 5060 (~556 MiB free) while the 3050/1070/1660S sat half
empty.

| Host | GPU | Physical | Used (old `-ts`) | Free | New `-ts` |
|------|-----|----------|------------------|------|-----------|
| `inference` | 3060 | 12288 | 8745 | 3167 | **12** |
| `inference` | 5060 | 8151 | **7152** (OOM gate) | **556** | **8** |
| `orchestrator` | 3060 WDDM | 12288 | 9491 | 2618 | **10** |
| `secondary` | 1070 | 8192 | 4430 | 3678 | **7** (opt-in) |
| `pool-opt-in` | 1660S | 6144 | 3414 | 2335 | **5** (opt-in) |
| `hub` | 3050 | **6144** | 3118 | 2687 | **5** |

**KV vs native ctx:** attention KV is ~16 KiB/token pool-wide (`q4_0`). Old
`CTX_SIZE=163840` ≈ **2.5 GiB**; native max **262144** ≈ **4.0 GiB** (+1.5 GiB,
spread by `-ts`). True 2× total (`327680`) exceeds Qwen3.8 native 262144 and
needs YaRN ([Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) — "natively
supports context lengths of up to 262,144 tokens"). inference coordinator has no
YaRN/`--override-kv` path (that is Pool72). Do **not** set 327680.

**RAG (embed + rerank) moved to CPU on `inference`** (**48 GiB**, i7-9700K) 2026-07-09 —
freed VM100's 1660 Super to become inference shard `:31354` above. See
[.cursor/plans/RAG_248_VM100_SHARD.md](../.cursor/plans/RAG_248_VM100_SHARD.md).
**`secondary` (GTX 1070, `:31355`)** and **`pool-opt-in` (1660 Super, `:31354`)** are **opt-in** shards at cluster start (Y/N like gaming hosts); `secondary` uses hub image
`alfa-llamacpp-rpc:cuda128-pascal` (Pascal sm_61). Operator gate: NVIDIA driver +
Docker on `secondary` before first join — [DOCKGE_248_OPERATOR.md](DOCKGE_248_OPERATOR.md).
**`hub` RTX 3050** = pool tail shard `:31353` + **CPU coordinator** `:31360` (only GPU
on `hub`; **RTX 5060 moved to `inference` `:31357`**, Jul 2026). **Petals retired** (2026-07-09).

**RAG:** orchestrator `start-rag` on `inference` after coordinator `/health` 200; legacy `pool-opt-in`/`hub` RAG stopped on cluster stop. Reranker is **Qwen3-Reranker-0.6B only** (no BGE fallback) — seed on `hub` before start: `sudo bash scripts/seed-qwen3-reranker-gguf-hub.sh`. Warm starts read **local** trees via `ensure-rag-models-local-cache.sh` (`~/alfa-ai-cache/rag/`), not NFS.

**Local-first (warm start I/O):** every shard/coordinator host keeps `alfa-llamacpp-rpc:cuda128` in Docker (skip hub load). Windows skips SMB when the image is present. `hub` binds the 27B GGUF from `/mnt/ssd/...` after `promote-gguf-to-ssd.sh`. Details: [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) § Local-first start.

## Crash prevention: readiness gating, restart policy, isolation

The coordinator `ggml_abort()`s (SIGABRT / exit 134) with
`ggml-rpc.cpp: "Remote RPC server crashed or returned malformed response"` when it
dispatches compute to a shard whose RPC session is bad. llama.cpp RPC has **no
fault tolerance** -- one bad backend kills the coordinator. The historic failure
mode was a **false-green race**: a `nc -z` TCP check passed on a shard whose port
was open but whose compute was wedged, so the first real decode (keep-warm or a
contracts-bot request) crashed the coordinator.

Six guards prevent this. All are on by default.

1. **Real compute self-test gate (not just `/health`).** Official
   [llama-server `/health`](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
   returns 200 when the model is loaded -- not a proven decode. RPC is a fragile
   PoC ([tools/rpc/README.md](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)).
   After `/health`, `start-pool` runs one real 4-token decode via
   `selftest-grev27-coordinator.sh`. The orchestrator then runs the **same** gate
   **before** `start-brain` / LiteLLM (not after). A concurrent LiteLLM completion
   during start can stall a PARALLEL slot and make a late self-test hang with
   HTTP 000. (Skip only for debugging: `inference_SKIP_SELFTEST=1`.)

2. **Shards are `restart: "no"`.** A crashed `rpc-server` must **stay down and fail
   the gate**, never silently auto-reopen its port (which produced the false green).
   The coordinator is already `restart: "no"`. A crashed shard requires the ordered
   recovery below -- never a bare `docker start`.

3. **Ordered recovery (never reconnect a fresh coordinator to a wedged shard).**
   If the orchestrator's compute self-test fails, it redeploys **all shards in the
   active list first** (`inference` dual, `orchestrator`, **opt-in** `secondary`/`pool-opt-in`, **opt-in** `gaming-a`,
   then `hub` shard + coordinator), then re-tests. Skipping a host that is still in
   still in `RPC_BACKENDS` leaves a stale backend and the recovery self-test fails
   again. Each shard deploy must run `inference-stop-local.sh` (shard mode) **before**
   `preflight-gpu-empty.sh` so the old `rpc-server` releases VRAM (VM100 holds
   ~2 GiB; skipping stop fails with `GPU 0: 2156 MiB used`). Piecemeal
   coordinator-only restarts against a wedged shard re-crash immediately -- do not
   do them by hand (see [cluster-start-stop-only](../.cursor/rules/cluster-start-stop-only.mdc)).

4. **No post-coordinator shard-port probing (official rpc-server model).** The
   llama.cpp `rpc-server` serves **one client at a time**: it `accept()`s a single
   socket, then runs `rpc_serve_client()` in a loop until that client disconnects,
   and only then loops back to `accept()`
   (`ggml/src/ggml-rpc/ggml-rpc.cpp` server loop). While the coordinator is
   connected -- i.e. the entire time the pool is loaded and serving -- the shard is
   **not** in `accept()`. A `nc -z` / `Test-NetConnection` probe to a shard RPC port
   after the coordinator has connected is therefore racy and semantically wrong, and
   a probe that sends non-HELLO bytes wedges the shard
   (`Expected HELLO command, update client`). **The orchestrator must never probe
   shard RPC ports after the coordinator is up, and must never redeploy a shard
   while the coordinator holds its session** (that kills the backend -> SIGABRT).
   Shard ports are verified **only before** the coordinator starts; after that the
   **only** valid pool health signal is a real decode through the coordinator
   (guard 1). Source: [ggml-org/llama.cpp rpc-server](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md).

5. **LAN firewall allowlist on shard ports.** Only the coordinator IP (`hub`) and
   loopback may reach `31350/31353/31356/31357`; stray clients that send non-HELLO
   bytes wedge a shard (`Expected HELLO command, update client`). Apply per Linux
   shard host (operator, one-time):

   ```bash
   sudo COORDINATOR_IP=hub RPC_PORTS="31356 31357" \
     bash deploy/cluster-members/_common/restrict-rpc-shard-firewall.sh
   ```

   `orchestrator` uses the Hyper-V/WSL rule from `install-wsl-lan-firewall.ps1`.

6. **Server prompt cache disabled (`--cache-ram 0`).** `llama-server` enables a RAM
   prompt cache by default (`-cram, --cache-ram` default **8192 MiB**) and saves idle
   slots on each new task (`--cache-idle-slots`, default enabled) per the
   [server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
   The save calls `state_seq_get_data()`, which cannot read KV owned by the **RPC**
   backend and aborts the coordinator with exit **134**
   ([#26128](https://github.com/ggml-org/llama.cpp/issues/26128),
   [#26529](https://github.com/ggml-org/llama.cpp/issues/26529)). Because deploy leaves
   all `PARALLEL` slots warm, the abort lands on the **first real user request** while
   deploy and self-test both look green. Every `--rpc` coordinator therefore passes
   `--cache-ram 0` (`CACHE_RAM` env). In-slot prefix reuse (`--cache-reuse`) is
   unaffected. Details: [inference_RPC_RELIABILITY.md](inference_RPC_RELIABILITY.md) item 6.

**Operator rule:** never `docker start` a single shard or restart the coordinator
alone after a crash. Run a full `Start-Stop-AlfaAi.ps1 stop` then `start`; the
orchestrator applies guards 1-3 automatically.

## VRAM budget

| Layout | Physical GPU VRAM | Nominal `-ts` sum | Model weights | Headroom (approx.) |
|--------|-------------------|-------------------|---------------|--------------------|
| **4-shard Q8 core (2026-09-11)** | **~38 GB** (12+8+12+6) | **35.0 GB** | ~29 GB (`Qwen3.8-27B-Q8_0`) | ~6–9 GB KV/compute |
| **6-shard mesh (`secondary`+`pool-opt-in`)** | **~52 GB** | **47.0 GB** | ~29 GB | ~18 GB |
| **7-shard all inference opt-in** | **~60 GB** | **52.0 GB** | ~29 GB | ~23 GB |
| **Q4 multi-slot rollback** | same mesh | same `-ts` | ~17.6 GB (`UD-Q4_K_XL`) | extra KV/slots |

**`CTX_SIZE=262144`** with **`PARALLEL=5`** (2026-09-11 VRAM squeeze) —
**52428 tokens/slot** (`262144 / 5`). That is Qwen3.8 **native** max. Slot budget:
**2 interactive/user + 3 automated**. Assumes **gaming-worker-a `gaming-a` joins** at the next
`Start-Stop-AlfaAi.ps1 start` (answer **Y**). Without `gaming-a`, `hub` 3050 / `inference`
5060 may OOM at **`UBATCH_SIZE=1024`**. **OOM rollback order:** `UBATCH_SIZE`
**1024 → 512** first, then **`PARALLEL` 5 → 4** (52428 → 65536/slot). Do not raise
`CACHE_RAM` or enable CUDA graphs. Do not raise past 262144 without YaRN.
Set total ctx to **`T × P`** per official llama-server guidance
([Discussion #4130](https://github.com/ggml-org/llama.cpp/discussions/4130);
per-slot = total ÷ `P` per [PR #17767](https://github.com/ggml-org/llama.cpp/pull/17767)).
Prefill: **`--batch-size 8192`** / **`--ubatch-size 1024`**
([server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)).
Perf / shards / LAG / MTP / slot budget: [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md).
Production GGUF: [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF)
`Qwen3.8-27B-Q8_0.gguf` (~29 GB). Architecture:
[Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B). Same RPC mesh,
**`PARALLEL=5`**, **`CTX_SIZE=262144`**. **Rollback (hub only):**
`inference_MODEL_FILE=Qwen3.6-27B-Q8_0.gguf` +
`ALFA_inference_FAMILY=qwen36` ([unsloth/Qwen3.6-27B-GGUF](https://huggingface.co/unsloth/Qwen3.6-27B-GGUF),
~28.6 GB) -- env rollback, then full stop+start; do not invent a new
`InferenceMode` radio for 3.6.

**Next production GGUF bump (same 27B class):** follow
[inference_MODEL_UPGRADE.md](inference_MODEL_UPGRADE.md) (hub seed, defaults,
`ALFA_inference_FAMILY` labels, keep served id `qwen3.6-27b`, brain
`BUILD_HASH`, full stop+start). Worked example: 3.6 → 3.8.

**LiteLLM / coordinator served id (unchanged):** keep
`MODEL_ALIAS=qwen3.6-27b` (`openai/qwen3.6-27b` on the coordinator). LiteLLM
[model_name aliases](https://docs.litellm.ai/docs/proxy/configs) map
`frontier-code`, `frontier`, and compat tiers to that backend id -- **do not**
rename the llama.cpp served model id (404 risk). Production
`deploy/litellm_config.inference.yaml` **must** include **`frontier`** as an alias
to the same backend as `frontier-code` (Ask ALFa and some clients send
`model=frontier`; omitting it yields HTTP 400 `Invalid model name`).

**Web picker labels:** aliases stay `frontier-code` / `qwen3.6-27b`. Display
names follow allowlisted `ALFA_inference_FAMILY` (`qwen38` production default, or
`qwen36` rollback) in `deploy/.env` (no freeform `CHAT_MODELS` pipe labels on
the public picker). `switch-pool-27b.sh` sets family from `inference_MODEL_FILE`.
Recreate **brain only** (`scripts/start.sh`) to refresh the dropdown; do not
restart shards. **`inference_38` test radio retired** -- normal **inference** start
loads 3.8.

**Web chat vs Cursor threads:** ALFa resends the **full transcript** every
turn (`POST /alfa-ai/api/chat`). Cursor keeps a live agent KV session.
llama.cpp can reuse a matching prefix
([server slot cache](https://github.com/ggml-org/llama.cpp/discussions/13606))
but Qwen3.6/3.8 are hybrid Gated DeltaNet stacks
([Qwen3.8-27B model card](https://huggingface.co/Qwen/Qwen3.8-27B));
`CACHE_REUSE` is limited on recurrent layers
([inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md)). Keep-warm pings
also occupy all `PARALLEL` slots, so a long thread often **cache-misses**
and prefills the whole history. At ~90-190 s TTFT even for "pong" (production 3.8 on full mesh measured
**~191 s** for Instruct "pong", decode **~4.4 tok/s** -- accepted for the
production flip; not comparable to historical 3.6 core-only **~3.7 s** TTFT),
a prior nginx-script thread exceeds the brain 600 s chat timeout and the UI
shows the generic unavailable banner. Use **New chat** + **Instruct** for
simple prompts; do not expect Cursor-like instant follow-ups on this RPC mesh.

Qwen3.6-27B is a **hybrid architecture** ([HF README](https://huggingface.co/Qwen/Qwen3.6-27B)):
64 layers, **16** Gated Attention layers carry context-dependent KV (`n_kv_heads=4`,
`head_dim=256`); **48** Gated DeltaNet layers use **fixed** recurrent state
(independent of `n_ctx`). With `CACHE_TYPE_K/V=q4_0`, attention KV scales as:

`KV_attn ≈ 2 × 16 × 4 × 256 × ctx_total × 0.5 bytes` → **~16 KiB per token**
pool-wide across the 16 attention layers.

| Step | `ctx_total` | Est. attention KV (pool) | Notes |
|------|-------------|--------------------------|-------|
| `PARALLEL=3`, `CTX=49152` | 49152 | ~768 MiB | prior |
| `PARALLEL=3`, `CTX=163840` | 163840 | ~2.5 GiB | ~54k/slot (Q8 if drop 1 auto) |
| `PARALLEL=4`, `CTX=163840` | 163840 | ~2.5 GiB | 40960/slot (prior Q8; 2+2) |
| `PARALLEL=4`, `CTX=262144` | 262144 | ~4.0 GiB | 65536/slot (prior Q8; 2+2) |
| **`PARALLEL=5`, `CTX=262144`** | **262144** | **~4.0 GiB** | **52428/slot (native max; 2+3)** |
| `PARALLEL=6`, `CTX=196608` | 196608 | ~3.0 GiB | 32768/slot (prior) |
| `PARALLEL=8`, `CTX=131072` | 131072 | ~2.0 GiB | 16384/slot (prior) |
| `PARALLEL=10`, `CTX=163840` | 163840 | ~2.5 GiB | 16384/slot (Q4 multi-slot rollback) |

Q8 weights dominate VRAM (~29 GB); attention KV at 262k total is ~4 GiB pool-wide.
Verify `nvidia-smi` on every shard after full start — the OOM gate under the old
split was the **overweight `inference` 5060**, not the 3050/1070/1660S tails. After
rebalance, watch the 5060 (8 GB) and `hub` 3050 (now a full **5** share) first.

**Slot context (official `llama-server`):** `--ctx-size` is the **total** KV
budget. With explicit `--parallel N` and without `--kv-unified` (our compose),
each slot is capped at `CTX_SIZE / N` even when only one request is active.
Live check: `GET /props` → `total_slots` and per-slot `n_ctx`.

Decode tok/s is usually **RPC/LAN-bound**, not KV; prefill scales with **actual
prompt size** and `--batch-size`.

## Model artifact

| Field | Value |
|-------|-------|
| HF repo | `unsloth/Qwen3.8-27B-GGUF` |
| File | `Qwen3.8-27B-Q8_0.gguf` (~29 GB on disk) |
| Rollback file (3.6 Q8) | `Qwen3.6-27B-Q8_0.gguf` (~28.6 GB; keep on hub) |
| Rollback file (Q4 multi-slot) | `Qwen3.6-27B-UD-Q4_K_XL.gguf` (~17.6 GB; keep on hub) |
| Hub path (`hub`) | `/mnt/HDDs/Alfa-AI/llama-cpp/models/` |
| Worker NFS (`inference`) | `/mnt/cluster/llama-cpp/models/` |
| LiteLLM alias | `frontier-code` / `frontier` / `qwen3.6-27b` |
| Endpoint | `http://127.0.0.1:31360/v1` (brain on `hub`) |
| Seed | `inference_GGUF_PROFILE=q8 sudo bash scripts/hub_hub_models.sh pull gguf27` |

## Mutual exclusion

- **27B coordinator on `hub` CPU `:31360`**; **35B MoE coordinator on `hub` CPU `:31360`** -- only one at a time.
- Stop the other pool before switch (`switch-pool-27b.sh` vs `switch-pool-35b.sh` on `hub`).
- Stop Ollama on shard GPUs before rpc-server start.

### VRAM bang-for-buck (core 35 GB; max inference opt-in ~52 GB `-ts`)

**Recommended production:** one Qwen3.8-27B **Q8_0** pool across **active** shards with
**`PARALLEL=5`** / **`CTX_SIZE=262144`** (52428/slot; 2 user + 3 automated). See
[inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md) before raising slots.
**Dense ~70–72B Q4:** exclusive **Pool72** full mesh (`gaming-c`/`gaming-a`/`gaming-b`/`secondary`/`pool-opt-in`);
**`gaming-c`/`gaming-b`** are inference opt-in (`:31351`/`:31358`) when not training; same ports
serve Pool72/80 — not concurrent 27B + dense 72B/80B on one GPU. Fit research:
[experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md](experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md).

**Avoid:**

| Layout | Why not |
|--------|---------|
| Two 27B pools | `rpc-server` is single-client per shard; splitting GPUs slows both |
| Concurrent 27B + 35B on shared shards | Impossible — pools are switch-only |
| Always-on ~80B Q4 filling ~48 GB | `PARALLEL` ~1; SWE behind dense 27B |

**Future `frontier` upgrade:** evaluate a **dense ~70–72B GGUF** on the same RPC
pool only after 6-shard + `PARALLEL=5` is stable; until then **`frontier` ==
`frontier-code`** (same `:31360` backend).

---

## Runbook (ordered)

### Phase 0 ? Repo

**From `inference` hub:** `git pull --ff-only origin main`. **From `orchestrator`:** orchestrator preflight syncs `inference` + `pool-opt-in`.

## Phase 0 ? Hub image (`hub` builder + NAS)

**Docker preflight (every host, before any llama.cpp RPC step):**

```bash
bash deploy/cluster-members/_common/preflight-docker-engine.sh
```

On `hub` if daemon was stopped: `sudo systemctl start docker` then re-run preflight.
Cluster target: Docker Engine **28.x+** on all pool hosts (`hub` hub build, `orchestrator` WSL, `inference`).
Stop on errors if preflight exits non-zero.

Build once on `hub`, publish to `/mnt/HDDs/Alfa-AI/docker-images/`. Workers **never** build or pull from `orchestrator`/`inference`.

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo bash scripts/pack-llamacpp-vendor-tarball-on-hub.sh b8552
sudo bash scripts/build-llamacpp-rpc-cuda128-on-hub.sh
```

Requires **b8552+** (llama.cpp PR [#21030](https://github.com/ggml-org/llama.cpp/pull/21030)) for
Mixed RPC pool (`hub` 3050 + `inference` 5060/3060 + `orchestrator` 3060).

Remove stale tarballs on hub (operator):

```bash
sudo rm -f /mnt/HDDs/Alfa-AI/docker-images/alfa-llamacpp-rpc-cuda128-b8352.tar.gz
sudo rm -f /mnt/HDDs/Alfa-AI/docker-images/alfa-llamacpp-rpc-cuda128-b8352-single.tar.gz
sudo rm -f /mnt/HDDs/Alfa-AI/docker-images/alfa-llamacpp-rpc-cuda128.tar.gz
```

Verify manifest:

```bash
python3 -c "import json; print(json.load(open('/mnt/HDDs/Alfa-AI/docker-images/images.json')))"
```

### Phase 0b ? Purge wrong images on every worker

**`orchestrator` (operator WSL):** `bash deploy/cluster-members/_common/purge-llamacpp-rpc-images.sh`

**`inference`:** same script path after `git pull`

**`hub`:** `sudo bash deploy/cluster-members/_common/purge-llamacpp-rpc-images.sh`

Then each host: `bash deploy/cluster-members/_common/load-llamacpp-rpc-from-hub.sh` (must match `images.json` id).

### Phase 1 ? Hub model (`hub`)

```bash
sudo bash scripts/hub_hub_models.sh verify gguf27
```

### Phase 2 ? GPU shards (four hosts)

Shard order in `inference-shards.env` is fastest-first. Remote shards (`orchestrator`, `inference`)
must be listening before the operator runs **start-pool** on `hub` (3050 shard +
CPU coordinator).

**`orchestrator` (operator):**

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\deploy-grev27-pool-shard.ps1
```

**`inference` (operator)** ? RTX 3060 `:31356` + RTX 5060 `:31357` shards:

```bash
cd ~/alfa-ai && bash deploy/cluster-members/inference-coordinator/deploy-grev27-pool-shard.sh
```

Verify TCP from **`inference` hub** (canonical cross-host check; orchestrator runs this automatically):

```bash
cd ~/alfa-ai
inference_VERIFY_RETRIES=30 bash deploy/cluster-members/_common/verify-inference-shards.sh
```

Must show OK for **orchestrator**, **orchestrator**, **orchestrator**
(and **hub** after operator start-pool).

**`orchestrator` WSL / firewall:** if `inference` cannot reach **`:31350`**, confirm mirrored
networking and Hyper-V firewall per [WINDOWS_WSL_DOCKER_ENGINE.md](WINDOWS_WSL_DOCKER_ENGINE.md)
(`firewall=true` in `.wslconfig`). One-time install (Administrator as `operator` on `orchestrator`):

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\_common\install-wsl-lan-firewall.ps1 -Profile operator-93
```

Then `wsl --shutdown` and re-run the full orchestrator **stop** + **start** cycle.

From `inference` (local shard check only):

```bash
bash deploy/cluster-members/_common/verify-inference-shards.sh
```

### Phase 3 ? `hub` start-pool (automated from `orchestrator`)

After remote shards pass preflight, the `orchestrator` orchestrator runs (via `inference` hub SSH jump):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start
```

That invokes `operator-cluster-111.sh start-pool` on `hub` (env switch, RTX **3050** shard
`:31353`, CPU coordinator `:31360`). **One-time prerequisite:** `operator` `sudo_commands_nopasswd`
on `hub` per [POOL_SWITCH_OPERATOR.md](POOL_SWITCH_OPERATOR.md) (A11).

Manual equivalent (repair / debug only):

```bash
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/operator-cluster-111.sh start-pool
```

Or piecemeal: `switch-pool-27b.sh` → `deploy-grev27-pool-shard.sh` → `deploy-grev27-pool-coordinator.sh`.

Sets `LLAMACPP_CODE27_URL=http://host.docker.internal:31360/v1` in brain `deploy/.env`
(LiteLLM bridge -> host-network coordinator on `hub:31360`; host probes use `127.0.0.1:31360`).
Stop Petals on `hub` before the 3050 shard deploy (single GPU).

### Phase 4 ? LiteLLM + brain stack (`hub`, automated)

**Canonical start:** the `orchestrator` orchestrator runs `operator-cluster-111.sh start-brain` after
coordinator `/health` and RAG verify pass. That script calls `scripts/start.sh`, which checks the
**27B coordinator on `hub:31360` first**, starts Postgres + Redis, then LiteLLM + API + nginx, and
runs **`scripts/brain_verify.sh`**.

**Manual (repair / debug only):** from repo root on `hub`:

```bash
sudo bash scripts/start.sh
```

This checks the **27B coordinator on `hub:31360` first**, starts Postgres + Redis,
then LiteLLM + API + nginx, and runs **`scripts/brain_verify.sh`** (operator
`:8420` login path, LiteLLM liveliness, 27B health).

API-only rebuild (after code change):

```bash
sudo bash scripts/brain_redeploy_api.sh
```

LiteLLM on the brain stack requires **in-stack Postgres and Redis** before it can
start. `deploy/litellm_config.yaml` enables Redis response cache (`cache: true`);
LiteLLM also runs Prisma migrations against the dedicated Postgres (`alfa-postgres` from the protected stack). Recreating
**`alfa-ai-litellm` alone** while Redis or Postgres is stopped causes liveliness
timeout or `(unhealthy)` ? use **`scripts/start.sh`** or **`hub-111/deploy.sh`**
instead of piecemeal recreate.

**Manual (if needed):**

1. Set in `deploy/.env`:

   ```
   LLAMACPP_CODE27_URL=http://host.docker.internal:31360/v1
   ```

   (LiteLLM bridge -> host-network coordinator; host health probes use `127.0.0.1:31360`.)

2. External network (once, if missing):

   ```bash
   sudo docker network create tunnel_network
   ```

3. Start Redis + Postgres, then app services:

   ```bash
   cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
   # DBs are in dedicated protected stacks; bring them up via their compose files or Dockge stacks
   sudo docker compose --env-file .env -f docker-compose.redis.yml up -d
   sudo docker compose --env-file .env -f docker-compose.postgres.yml up -d
   sudo docker compose --env-file .env up -d alfa-ai-litellm alfa-ai-api alfa-ai-nginx
   bash ../scripts/brain_verify.sh
   ```

### Verify

Coordinator health:

```bash
curl -fsS http://127.0.0.1:31360/health
```

LiteLLM `frontier-code` smoke (first completion may take several minutes):

```bash
bash scripts/smoke-grev27-litellm-chat.sh
```

### Phase 5 -- 27B-only picker + LiteLLM routing

After coordinator and shards are green, **`switch-pool-27b.sh`** on `hub` sets:

| Variable | Value |
|----------|-------|
| `LLAMACPP_CODE27_URL` | `http://host.docker.internal:31360/v1` (`.env`; LiteLLM bridge) |
| `ALFA_INFERENCE_MODE` | `inference` |
| `CHAT_MODELS` | `frontier-code,qwen3.6-27b` |
| `ALFA_inference_FAMILY` | `qwen38` (production 3.8) or `qwen36` (3.6 rollback via env) |
| `DEFAULT_MODEL` | `frontier-code` |
| `LITELLM_CONFIG` | `litellm_config.inference.yaml` |

Recreate brain stack so API + LiteLLM pick up env:

```bash
sudo bash scripts/start.sh
```

**Benchmark:** record tok/s in [inference_BENCHMARKS.md](inference_BENCHMARKS.md) via
`bash scripts/benchmark-inference-litellm.sh` on `inference` hub.

**Cold start:** first completion after coordinator restart or long idle may take **~3-4 minutes**
(warm requests are sub-second). See [inference_BENCHMARKS.md](inference_BENCHMARKS.md) cold-start table.

**Keep warm (recommended on `hub`):** `bash deploy/cluster-members/hub/operator-cluster-111.sh install-keep-warm` then one manual `keep-inference-warm.sh` on `hub`. Warms **all** `PARALLEL` slots (default 5) via concurrent pings so interactive chat does not hit an unused-slot ~90 s TTFT. Retire `apps` cron via `bash scripts/install-inference-keep-warm-cron.sh --uninstall-only`. See [inference_BENCHMARKS.md](inference_BENCHMARKS.md).

**Diagnostics:** `bash scripts/diagnose-inference-ai.sh` on `inference` hub; `curl` contracts-bot on `apps`
`http://127.0.0.1:8002/api/health/connectivity`.

## contracts-bot (and every other repo) integration (27B pool mode)

While the **27B RPC pool** is active, per the **universal alias coverage** policy
([POOL_SWITCH_OPERATOR.md](POOL_SWITCH_OPERATOR.md#universal-alias-coverage-mandatory----default-for-every-consuming-repo)):

- **Native** for contracts-bot: LiteLLM alias `qwen3.6-27b` / `frontier-code` -> `LLAMACPP_CODE27_URL` (`hub:31360`).
- **All other standard aliases** (`fast`, `inline`, `autocomplete`, `chat`, `public-chat`,
  `app-chat`, `agent`, `code`, `operator_internal`, `qwen3.6:35b-a3b` -- used by rankings-bot,
  market-pie5-bot, etc.) are also registered in `litellm_config.inference.yaml`, routed to the
  same live **27B** model via `LLAMACPP_CODE27_URL`. No repo sees `Invalid model name` while
  inference is active, regardless of which alias it calls.
- Use **`litellm_config.inference.yaml`** (set by `switch-pool-27b.sh`) for 27B-only production;
  the combined `litellm_config.yaml` is dev/default only and should not be used in production
  for either pool.
- `CONTRACT_AI_FALLBACK_ENABLED` (and any similar per-repo fallback flag) is **no longer
  required** to avoid errors during 27B-only production -- the fallback alias now resolves
  server-side. Repos may still use such a flag to skip an unnecessary extra hop, but it is an
  optimization, not a correctness requirement.

To use 35B MoE again: run `switch-pool-35b.sh` on `hub` (stops 27B pool first).

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Coordinator **Exited (134)** / `Remote RPC server crashed` during brain start | Mixed GPU RPC pool needs **b8552+** on all shards + coordinator ([PR #21030](https://github.com/ggml-org/llama.cpp/pull/21030)). Rebuild hub image, purge + load on every host, full cluster start. |
| Degraded AI / shards flapping / partial pool | **Full stop then full start** via [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) with host log tails open. Do not chain individual redeploys. |
| LiteLLM **503 Loading model** during brain start (localhost -> `:31360`) | Expected while coordinator loads tensors. `start.sh` waits `/health` 900s **before** LiteLLM up; `litellm_config.inference.yaml` disables `background_health_checks`. Do not redeploy coordinator mid-start. |
| contracts-bot UI **degraded** / `contract_ai_ready: false` | Shards TCP OK? Run `verify-inference-shards.sh`. After start completes, `keep-inference-warm.sh` records success. Stale 503 errors in detailed health clear on next success. |
| All shards **FAIL** but coordinator `/health` 200 | GPU rpc-server containers stopped; run **full cluster start**, not coordinator-only redeploy. |
| KV OOM on `inference:31357` | Confirm `TENSOR_SPLIT` line for 5060 shard is **8**; RAG embed/rerank run CPU-only on `inference`, not the 5060/3060 |
| RPC wedge / split-brain | [inference_RPC_RELIABILITY.md](inference_RPC_RELIABILITY.md) — stagger startup, full stop+start |
| Shard missing from pool | Edit `inference-shards.env`, run `write-grev27-pool-env-from-shards.sh`, redeploy coordinator |
| Stale coordinator containers | `docker rm -f llamacpp-server-148-grev27-pool llamacpp-server-111-grev35` then redeploy |
| 27B vs 35B conflict | Both use **`hub:31360`** for coordinator; run only one `switch-pool-*` at a time |
| LiteLLM wrong model | `LLAMACPP_CODE27_URL` must be `http://host.docker.internal:31360/v1` in `deploy/.env` (or `127.0.0.1:31360` for host-side probes only) |
| LiteLLM liveliness timeout / `(unhealthy)` | `docker ps` ? ensure dedicated `alfa-redis`/`alfa-postgres` (protected stacks) are up before `--force-recreate alfa-ai-litellm`; check logs for redis:6379 or Postgres connection errors |
| `tunnel_network` not found | `sudo docker network create tunnel_network` once, then recreate LiteLLM |
| `failed to set up container networking: network <id> not found` on `start-brain` | Stale container still points at a deleted Docker network ID (Compose reuse without recreate). `alfa_compose_brain_up` retries with `--force-recreate`. Manual: `cd .../deploy && sudo docker compose up -d --force-recreate --no-build alfa-ai-litellm alfa-ai-api alfa-ai-nginx`. Then full `Start-Stop-AlfaAi.ps1 stop` + `start` if the orchestrator already failed mid-start. |

