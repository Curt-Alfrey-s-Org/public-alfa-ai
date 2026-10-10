# Experimental: UI-driven model + GPU assignment — operator research

**Status:** Research complete (2026-07-18). Plan remains **paused for build** until operator
explicit green-light. Plan file (do not edit from agents):
`~/.cursor/plans/experimental_gpu_model_ui_e78c230b.plan.md`.

**Goal (aspirational):** Admin UI picks model class (14B / 27B / 35B / 72B dense) and assigns
free GPUs; spin stacks up/down. Optional second brain/coordinator on `inference` (max **2**
cluster-wide). Primary brain stays on `hub`.

This doc closes the plan research checklist. It cites repo measurements and official
llama.cpp RPC behavior only ([RPC README](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md),
[multi-gpu / tensor-split](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md)).

---

## 1. Fleet GPU inventory (Jul 2026)

Physical VRAM is from `nvidia-smi` / [NODE_INVENTORY.md](../NODE_INVENTORY.md). **Shard slice**
is what inference tensor-split uses ([inference-shards.core.env](../../deploy/llamacpp-rpc/inference-shards.core.env),
[gaming catalog](../../deploy/llamacpp-rpc/inference-shards.gaming.env)).

| Host | GPU | Physical VRAM | Always-on port | Slice (GB) | Membership |
|------|-----|---------------|----------------|------------|------------|
| `inference` | RTX 3060 | 12 GB | `:31356` | 12 | core |
| `inference` | RTX 5060 | 8 GB | `:31357` | 8 | core |
| `orchestrator` | RTX 3060 | 12 GB | `:31350` | 10 | core |
| `hub` | RTX 3050 | 6 GB | `:31353` | 5 | core |
| `gaming-a` | RTX 5060 | 8 GB | `:31352` | 5 | opt-in gaming-worker-a-219 |
| `gaming-c` | RTX 5070 | 12 GB | `:31351` | 9 | opt-in gaming-worker-c-59 |
| `gaming-b` | RTX 5070 | 12 GB | `:31358` | 9 | opt-in gaming-worker-b-249 |
| `secondary` | GTX 1070 | 8 GB | `:31355` | 7 | opt-in gpu-248 |
| `pool-opt-in` | GTX 1660 Super | 6 GB | `:31354` | 5 | opt-in vm100-100 |

**Totals** (must match `inference-shards.core.env` + `inference-shards.gaming.env`)

| Set | Physical VRAM | inference `TENSOR_SPLIT` sum (nominal GB) |
|-----|---------------|----------------------------------------|
| Always-on core (4 shards) | ~38 GB | **35.0** (`12,8,10,5`) |
| + all opt-in (`gaming-a`/`gaming-c`/`gaming-b`/`secondary`/`pool-opt-in`) | **~84 GB** | **70.0** (`12,8,5,9,9,10,7,5,5`) |

**2026-08 note:** `secondary` and `pool-opt-in` moved from "core" to **opt-in** (same catalog as
gaming). Older "6-shard always-on ~45 GB" rows in archived prose are stale.

Coordinator: **CPU on `hub` `:31360`** only. `inference` coordinator is **hard-rejected**
([deploy-grev27-pool-coordinator.sh](../../deploy/cluster-members/inference-coordinator/deploy-grev27-pool-coordinator.sh)).

---

## 2. Model class VRAM and tensor-split (hypothesis tables)

Exact GGUF tags and floors need operator confirmation after one measured load per class.
Numbers below use hub artifacts and repo runbooks.

### ~14B dense

| Field | Estimate | Source / note |
|-------|----------|---------------|
| Example GGUF | DeepSeek-R1-Distill-Qwen-14B Q4, Qwen2.5-Coder-14B Q4 | [JUDGE_INSTALL_59.md](../operations/JUDGE_INSTALL_59.md) |
| Weights (Q4) | **~8–10 GB** | Typical 14B Q4_K band |
| Min topology | **1× 12 GB GPU** standalone `llama-server`, or 2× 6–8 GB RPC shards | No fleet benchmark yet |
| Concurrent with 27B pool | **Yes, if GPUs disjoint** | e.g. 14B on `gaming-c` while core pool uses other hosts |
| Tensor-split | Usually unnecessary on single 12 GB card | RPC only if splitting across 8 GB cards |

**Operator action:** Smoke 14B on `gaming-c` or `gaming-b` alone (`PARALLEL=1`); record load time and
`nvidia-smi` peak.

### ~27B dense (production)

| Field | Value | Source |
|-------|-------|--------|
| GGUF | `Qwen3.8-27B-Q8_0.gguf` | [GREV27_27B_OPERATOR.md](../GREV27_27B_OPERATOR.md) |
| Weights | **~29 GB** | Hub / promote script |
| Topology | 4 always-on RPC shards + CPU coordinator; opt-in gaming/`secondary`/`pool-opt-in` | `inference-shards.core.env` |
| `TENSOR_SPLIT` (core) | `12,8,10,5` | 35.0 GB nominal |
| `TENSOR_SPLIT` (inference `gaming-a`+`secondary`+`pool-opt-in`) | `12,8,5,10,7,5,5` | 52.0 GB |
| `TENSOR_SPLIT` (inference all five opt-in) | `12,8,5,9,9,10,7,5,5` | 70.0 GB |
| Slots | `PARALLEL=5`, `CTX_SIZE=262144` (52428/slot; 2 user + 3 auto; native max) | [inference_PERF_AND_SHARDS.md](../inference_PERF_AND_SHARDS.md) |

### ~72B dense (exclusive) — **fit validated with gaming hosts**

Prior cluster research (this file, Jul 2026) concluded **Q4 ~70–72B fits** when
**`gaming-c` / `gaming-a` / `gaming-b` are in the mesh** (~84 GB physical / **70.0 GB** usable
`-ts` with current catalog slices). That is a **capacity** finding, not a claim that Qwen2.5-72B beats
current production Qwen3.8-27B on every benchmark.

| Field | Estimate | Source / note |
|-------|----------|---------------|
| Practical GGUF targets | **Qwen2.5-72B-Instruct** Q4_K_M (**locked** for Pool72; not Llama-3.3-70B) | [GREV72_72B_OPERATOR.md](../GREV72_72B_OPERATOR.md); official [Qwen GGUF](https://huggingface.co/Qwen/Qwen2.5-72B-Instruct-GGUF) |
| Weights (Q4_K_M) | **~41–43 GB** | HF / GGUF community sizes |
| Min topology | **Full mesh exclusive** (core + gaming + `secondary`/`pool-opt-in`) | User intent: 72B alone on the pool |
| Core-only (35.0 GB `-ts`) | **Too tight** for Q4 72B + KV | Do not attempt without opt-in hosts |
| Full mesh (~70 GB `-ts` / ~84 GB physical) | **Comfortable for weights + modest KV** | This research — gaming hosts matter |
| Tradeoffs vs production 27B | Tear down 27B; expect lower tok/s; **`PARALLEL≈1`** | Exclusive load |
| Quality note | Vendor: Qwen3 dense tops at **32B**; Qwen3.6-27B leads **coding** proxies vs older 72B | Fit ≠ "always smarter than 27B" — measure on your tasks |

**Tensor-split (illustrative):** stop 27B; load 72B GGUF from hub; regenerate split
from free VRAM; fastest-first order from [GREV27](../GREV27_27B_OPERATOR.md) —
`inference` 3060+5060, `gaming-a`, `gaming-c`, `gaming-b`, `orchestrator`, `secondary`, `pool-opt-in`, `hub` tail.

**Operator action:** One dry-run after full `Start-Stop` stop: 72B on hub only,
coordinator load with candidate split; record `selftest-grev27-coordinator.sh`
(or equivalent) + tok/s. **`frontier` alias** is reserved for this exclusive path
once measured.

### ~35B MoE

| Field | Value | Source |
|-------|-------|--------|
| GGUF | `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` | [GREV35_35B_OPERATOR.md](../GREV35_35B_OPERATOR.md) |
| Weights (total) | **~22–24 GB**; ~3B active/token | MoE |
| Topology | **Same GPU shards as inference**; coordinator `--fit on` | `pool35-shards.env` |
| Mutual exclusion | **One coordinator on `:31360`** — 27B or 35B, not both | [POOL_SWITCH_OPERATOR.md](../POOL_SWITCH_OPERATOR.md) |
| VRAM (legacy file) | ~32 GB nominal in runbook | Regenerate 35B env against current core + opt-in list |

**Operator action:** Benchmark pool35 cold start only if reviving; regenerate shard env first.

---

## 3. Cold-start and spin-up timing

### Measured on this cluster (27B inference)

From [inference_BENCHMARKS.md](../inference_BENCHMARKS.md) and [CLUSTER_START_STOP_OPERATOR.md](../CLUSTER_START_STOP_OPERATOR.md):

| Phase | Duration | Notes |
|-------|----------|-------|
| Coordinator `/health` not ready | **~2 min** | 503 "Loading model" |
| First completion after idle / restart (cold) | **~3–4 min** (218 s for 64 tok, 2026-06-29) | Includes RPC weight pull |
| Warm short completion | **sub-second to ~10 s** | Same benchmark: 0.2 s warm |
| Warm decode (5-shard, Jul 2026) | **~8.2 tok/s** decode | After `BENCH_WARMUP=1` |

Pool switch UI estimates ([POOL_SWITCH_OPERATOR.md](../POOL_SWITCH_OPERATOR.md)):

| Pool | UI `cold_start_estimate_sec` | Basis |
|------|------------------------------|-------|
| inference | **210** | ~3–4 min |
| pool35 | **240** | Placeholder until benchmarked |

### Estimated (unbenchmarked — operator must confirm)

| Action | Estimate | Why |
|--------|----------|-----|
| **14B** single-GPU load | **30–90 s** (guess) | One host, ~9 GB weights |
| **27B** membership change (add/remove shard) | **Full `Start-Stop-AlfaAi` cycle** + **3–4 min** coord load | Regenerate `inference-shards.active.env`, stagger shards, no hot-join ([RPC README](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)) |
| **35B** swap (same shards) | **~4 min** | Same as pool switch |
| **72B** exclusive bring-up | **15–30+ min** | Full stop all GPU stacks, redeploy all shards, coordinator load, self-test |
| **72B** teardown back to 27B | **Same order** | Another full cycle |

### Full cluster start (reference)

`Start-Stop-AlfaAi.ps1 start` includes git sync, shard deploy, coordinator self-test, brain,
RAG — **much longer** than pool switch alone. UI must not imply "pick GPUs like Cursor" latency.

---

## 4. Dual brain / second coordinator on `inference`

### Locked constraints (from plan thread)

1. Primary brain/coordinator stays **`hub`** (UI, LiteLLM, nginx).
2. Max **2** coordinators cluster-wide.
3. **No shared shards** — `rpc-server` is **single-client** ([GREV27 guard 4](../GREV27_27B_OPERATOR.md)).
4. `inference` today: **inference shards `:31356`/`:31357`** + **CPU RAG** embed/rerank.

### Feasibility matrix

| Scenario | Safe? | Verdict |
|----------|-------|---------|
| Brain-2 coordinator on `inference` **while** `inference` GPUs stay in brain-1 pool | **No** | Same ports; second client wedges/crashes pool |
| Brain-2 coordinator on `inference` CPU, GPUs on **disjoint** hosts only (e.g. `gaming-c`+`gaming-b`) | **Maybe** | Requires new coord port (e.g. `:31361`), LiteLLM alias, deploy path; `inference` script currently **errors** |
| Brain-2 on `inference` after **releasing** `inference` GPUs from brain-1 | **Maybe** | Shrinks brain-1 pool; full stop+start; RAG already on `inference` CPU — coord competes for RAM with embed/rerank |
| Move RAG to future `rag`, free `inference` RAM for brain-2 CPU | **Maybe** | Infra project; not required for single-brain UI |
| Two 27B pools splitting cluster GPUs | **No** | [inference_PERF_AND_SHARDS.md](../inference_PERF_AND_SHARDS.md): "Do **not** split GPUs into two 27B pools" |

### Recommendation (research conclusion)

**Second coordinator on `inference` is not worth the complexity for Phase 1.**

- `inference` GPUs are **core** production shards; removing them from brain-1 hurts 27B throughput.
- CPU coordinator on `inference` was **retired** in favor of `hub` colocated with LiteLLM.
- A second brain only pays off if you routinely need **two model classes at once** on **disjoint**
  GPU sets (e.g. 27B on core + 14B judge on `gaming-c`) — that is achievable today with **Ollama on
  `gaming-c`** without a second RPC coordinator ([JUDGE_INSTALL_59.md](../operations/JUDGE_INSTALL_59.md)).

**If revived later:** brain-2 should use a **non-overlapping** GPU set (likely gaming hosts only),
alternate coordinator port, and explicit LiteLLM routing — not `inference` shards that brain-1 already
owns.

---

## 5. Spin-up/down UX vs always-on pool

### What works today (without new UI)

| Mechanism | Latency | GPU control |
|-----------|---------|-------------|
| Always-on inference + keep-warm cron | Warm: seconds | Fixed core shards; gaming **Y/N at cluster start** only |
| Admin pool switch 27B ↔ 35B | **~3–4 min** with progress UI | **No** GPU pick — same shards |
| Chat model picker | **Routing only** | Does not start/stop GPUs ([POOL_SWITCH_OPERATOR.md](../POOL_SWITCH_OPERATOR.md)) |
| `Start-Stop-AlfaAi.ps1` | **Many minutes** | Console prompts for gaming opt-in |
| Ask ALFa `cluster_start` / `stop` | Full cycle | Fixed script; no GPU matrix ([host_catalog.py](../../src/ops/host_catalog.py)) |

### UX judgment

| Use case | Spin-up/down acceptable? |
|----------|---------------------------|
| Interactive admin chat / contracts scan | **No** for 3–4 min cold — keep **always-on + keep-warm** |
| Deliberate "try this GPU set" experiment | **Yes** if UI shows **honest timers** and requires **L2 Approve** |
| Switch to **72B exclusive** | **Yes** if operator expects **15–30+ min** and full teardown of 27B |
| Cursor-like instant model pick | **Not achievable** with RPC multi-host cold load on this fleet |

**Efficiency conclusion:** Dynamic spin-up/down is **research-valid** for **scheduled /
experimental** runs, not a replacement for production always-on inference. Prefer extending
**pool switch** + **non-interactive shard membership file** before a full GPU lease wizard.

---

## 6. Failure modes (UI must handle)

| Failure | Cause | Mitigation |
|---------|-------|------------|
| Partial start | Some shards up, coord loads, self-test fails | Ordered recovery or **full stop+start** — no piecemeal ([no-piecemeal-cluster-scripts](../../.cursor/rules/no-piecemeal-cluster-scripts.mdc)) |
| Gaming host offline after opt-in | Stale `RPC_BACKENDS` | Membership validation before start; show host reachability in UI |
| Exclusive 72B teardown incomplete | Shards still hold VRAM | `inference-stop-local.sh` on every host before 72B |
| Two coordinators one shard | Operator picked overlapping GPUs | **Lease table** must enforce disjoint sets (future) |
| LiteLLM 503 during load | Health probes during load | Already disabled in inference config ([CLUSTER_START_STOP_OPERATOR.md](../CLUSTER_START_STOP_OPERATOR.md)) |

---

## 7. Research checklist (plan) — status

| Item | Status | Notes |
|------|--------|-------|
| Cold-start vs willingness (per class) | **Documented** | 27B measured; 14B/72B need operator smokes |
| VRAM + tensor-split tables | **Documented** | §2; 72B split TBD by measurement |
| Two concurrent RPC pools worth it? | **No for Phase 1** | Use Ollama 14B on `gaming-c` or sequential pool switch |
| `inference` CPU coordinator after GPUs leave brain-1? | **Defer** | RAG on `inference` CPU; move to `rag` is separate capacity project |
| Gaming hosts UI-selectable without SSH-from-`orchestrator` | **Blocked** | `gaming-c`/`gaming-b` operator-only until agent SSH; prep scripts exist ([inference_GAMING_HOST_JOIN.md](../inference_GAMING_HOST_JOIN.md)) |
| Partial start / 72B teardown | **Documented** | §6 |

---

## 8. Resume gate — recommendation

**Build status:** remain **paused** until operator explicitly green-lights.

**Suggested thin Phase 1** (if green-light):

1. **Non-interactive GPU membership** for **brain-1 / 27B only** — extend existing
   `inference-shards.active.env` + admin POST with L2 Approve (reuse pool-switch executor pattern).
2. **No** second coordinator on `inference`.
3. **No** 72B exclusive mode until one successful operator dry-run (§2).
4. **No** replacement of always-on production default — experimental flag only.

**Kill criteria** (skip UI build entirely):

- Operator unwilling to wait **3–4 min** for routine model changes.
- No need for concurrent two-model runs (use pool switch + `gaming-c` Ollama judge instead).

**Operator green-light checklist:**

- [ ] Run 14B smoke on `gaming-c` or `gaming-b`; paste load time + VRAM
- [ ] Run pool35 cold benchmark on **6-shard** list; update `cold_start_estimate_sec`
- [ ] Optional: 72B dry-run teardown/restore cycle timed
- [ ] Explicit "approve Phase 1" message in chat or issue

---

## Related

- Plan (paused): `experimental_gpu_model_ui_e78c230b.plan.md`
- [GREV27_27B_OPERATOR.md](../GREV27_27B_OPERATOR.md)
- [inference_GAMING_HOST_JOIN.md](../inference_GAMING_HOST_JOIN.md)
- [AI_AUTONOMY_AND_OVERSIGHT.md](../AI_AUTONOMY_AND_OVERSIGHT.md) — L2 Approve for mutate
