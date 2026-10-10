# Qwen3 Migration — April 2026

> **PRIMARY WORKING SET — scenario #2 (operator-confirmed).** `gaming-c`/`gaming-a`/`gaming-b`
> are offline; production stays on four always-on hosts `orchestrator`/`apps`/`hub`/`inference`
> via **llama.cpp RPC** (CPU+GPU pool). Full-fleet scenarios deferred until those
> hosts are up. Plan:
> [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).

Record of the ALFa AI tier stack. **Current target (June 2026 operator-selected
upgrade):** tiers 0/1/2 are a **two-host CPU chat pool** — dense **`qwen3.5:27b`**
on **`gaming-c`** (quality default) and **`qwen3.6:35b-a3b`** MoE on **`orchestrator`** (speed);
each alias falls back to the other host, then `frontier`. **Llama-3.3-70B** on
**Petals** (tier **3a**); **Qwen3-Coder-Next-80B-A3B** on **llama.cpp RPC** (tier
**3b**, **GPU-only**, **mutually exclusive** with **3a** on VRAM). Embeddings =
**`qwen3-embedding:4b`** on `gaming-c`; reranker = **`Qwen3-Reranker-0.6B`** (sidecar,
not Ollama); **`hub` runs no Ollama at all** (App removed 2026-07-05) —
`operator_internal` routes to the RPC pool instead.
**Requires Ollama `0.30.x`** (Gated-DeltaNet) on the hosts that do run it — verify each tag loads before
retiring the old models. The May-2026 `gaming-c`-only `qwen3:32b` plan and the
April-2026 `qwen3-coder:30b-a3b-q4_K_M` CPU MoE fleet are **superseded** (kept
below for history). SoT: [`deploy/litellm_config.yaml`](../deploy/litellm_config.yaml)
+ [ROADMAP.md § "Operator-selected models (2026-06-17)"](ROADMAP.md#operator-selected-models-2026-06-17--confirmed).

**Ollama install / runtime:** [OLLAMA_INSTALL_GOTCHAS.md](OLLAMA_INSTALL_GOTCHAS.md) (audit OLLAMA-002 / backlog #24).

## Official sources (single source of truth)

Use these before trusting any cluster-local doc:

| Topic | Authoritative reference |
|-------|-------------------------|
| **Qwen3 model lineup** (dense + MoE parameter counts) | [Qwen3 blog — model tables](https://qwenlm.github.io/blog/qwen3/) |
| **Qwen3 in Hugging Face Transformers** (API, env: `transformers>=4.51.0`, `torch>=2.6` recommended) | [Qwen docs — Transformers](https://qwen.readthedocs.io/en/latest/inference/transformers.html), [HF model_doc/qwen3](https://huggingface.co/docs/transformers/model_doc/qwen3) |
| **What Petals supports** | [Petals README — supported model families](https://github.com/bigscience-workshop/petals) (Llama / Mixtral / Falcon / BLOOM — not Qwen3) |
| **Accuracy / benchmark audit (coding, IFEval, creative writing; vs this repo)** | [MODEL_FIT_AUDIT.md](MODEL_FIT_AUDIT.md) — cites Meta model card + Qwen3 Technical Report tables only |

**Corrections to common mistakes:**

- There is **no official “Qwen3-72B” dense** in the Qwen3 release table on the Qwen3 blog; largest **dense** Qwen3 is **32B**; flagship **MoE** is **235B-A22B** (22B activated).
- **Q6_K** is a **GGUF / llama.cpp** quant name. **Petals** serves **Hugging Face** checkpoints with its own loading path — do not describe Petals as loading “Q6_K” unless you are explicitly running **llama.cpp**.

> **SUPERSEDED (history).** **April 2026:** tiers 0/1/2 were a **CPU MoE**
> (`qwen3-coder:30b-a3b-q4_K_M`) latency-routed across four fleet hosts
> (`hub`/`orchestrator`/`gaming-c`/`gaming-b`). **May 2026:** dense **`qwen3:32b`** on **`gaming-c`
> only**; MoE + four-host fleet retired. **June 2026 (current — operator-selected
> upgrade):** a **two-host CPU chat pool** — `qwen3.5:27b` dense on `gaming-c`
> (quality) + `qwen3.6:35b-a3b` MoE on `orchestrator` (speed). See the Tier matrix below,
> [ROADMAP.md § "Operator-selected models (2026-06-17)"](ROADMAP.md#operator-selected-models-2026-06-17--confirmed),
> and [NODE_INVENTORY.md](NODE_INVENTORY.md) for current GPUs.

## Tier matrix - PRIMARY working set (four always-on hosts)

SSoT: [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).
Frontier runs on `orchestrator`/`apps`/`hub`/`inference` via **llama.cpp RPC**, one model at a time.

| Tier | Role | Model | Runtime | Host(s) | Footprint |
|------|------|-------|---------|---------|-----------|
| 3a | frontier-chat | **Qwen3.5-122B-A10B** (MoE 10B active) | llama.cpp RPC (pooled) | coordinator `orchestrator:31360` + backends `inference`/`hub` (+`apps`) | ~56 GB Q3 / ~72 GB Q4 across GPU+CPU |
| 3b | frontier-code | **Qwen3.6-27B** (dense) | llama.cpp RPC (2-GPU) | `orchestrator`+`inference` 3060 pool (24 GB) | ~17 GB Q4 (too big for one 12 GB card) |
| 3b alt | frontier-code (agentic) | **Qwen3-Coder-Next-80B-A3B** (MoE 3B active) | llama.cpp RPC (pooled) | coordinator `orchestrator` + all backends | ~46-52 GB Q4 |
| emb | embed | `qwen3-embedding:4b` | Ollama | **`pool-opt-in` 1660S** `:11435` (always-on) | ~2.5 GB |
| rerank | RAG reranker | `Qwen3-Reranker-0.6B` (GGUF) | llama.cpp sidecar | **`inference` CPU** `:8360` (mandatory) | ~0.6 GB |

Concurrency = llama.cpp `--parallel` slots (throughput, not failover); degraded
fallback = small always-on model on `hub`/`apps`. Caching + KV-quant +
context-extension levers: see SSoT plan §5.

## Tier matrix - OPPORTUNISTIC boost (only when gaming hosts online)

> Requires **Ollama `0.30.x`** (Gated-DeltaNet) on `gaming-c`/`orchestrator` — verify each tag
> loads before relying on it. Active only when `gaming-c`/`gaming-a`/`gaming-b` are online.

| Tier  | Role                          | Model                                   | Runtime       | Host(s)                          | Footprint          |
|-------|-------------------------------|-----------------------------------------|---------------|----------------------------------|--------------------|
| 0/1/2 quality | chat/agent/code/public-chat/app-chat | **`qwen3.5:27b`** (dense, text-only) | Ollama CPU | **`gaming-c`** (`OLLAMA_FLEET_59_URL`) | ~19 GB (Q5_K_M) |
| 0/1/2 speed | fast/inline/autocomplete       | **`qwen3.6:35b-a3b`** (MoE, ~3B active) | Ollama CPU | **`orchestrator`** (`OLLAMA_FLEET_93_URL`) | ~22 GB (Q4_K_M) |
| 3a    | frontier-chat                 | `meta-llama/Llama-3.3-70B-Instruct` (NF4) | Petals swarm | 7 hosts / 8 GPUs (76 GB)        | ~35–45 GB distributed |
| 3b    | frontier-code                 | `Qwen3-Coder-Next-80B-A3B-Instruct` Q4_K_M | llama.cpp RPC | coordinator + `rpc-server` on **every Petals GPU** (see runbook) | ~48.4 GB weights (GGUF) + KV; **mutually exclusive** with 3a on GPU |
| emb   | embed                         | `qwen3-embedding:4b`                     | Ollama        | `gaming-c` (primary), `gaming-b` (standby)| ~2.5 GB (**re-embed corpora on switch**) |
| rerank | RAG reranker | `Qwen3-Reranker-0.6B` | llama.cpp sidecar (**not Ollama**) | **`pool-opt-in` `:8360`** (mandatory; ~3 GiB combined with embed on 1660S) | ~0.6 GB |

**GPU-only note:** tier **3b** is **not** served from **CPU** Ollama. Tier **0/1/2** is the **two-host CPU pool** (`qwen3.5:27b` on `gaming-c` + `qwen3.6:35b-a3b` on `orchestrator`) — the May `gaming-c`-only `qwen3:32b` and the April four-host `qwen3-coder:30b-a3b-q4_K_M` MoE fleet are **superseded**. The **retired** GPU path is **llama.cpp RPC** for **`Qwen3-Coder-30B-A3B` GGUF** — replaced by **Coder-Next 80B** over the same mechanism.

**Fallback for 0/1/2 aliases:** each host falls back to the other (`gaming-c`↔`orchestrator`), then to **`frontier`** (Petals 70B).

Swarm VRAM total (Petals **3a** vs llama.cpp **3b** — **never both** on the same GPU): **76 GB** (`hub` 5060 8 + `apps` 1660S 6 + **`orchestrator` 2× 3060 12** +
`gaming-b` 5070 12 + `gaming-c` 5070 12 + `gaming-a` 5060 8 + `secondary` 3050 6).

**6 GB GPUs (`apps`, `secondary`):** last integration step for **3b** — do not assume they join the **80B** shard set until validated against upstream memory guidance (see [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) § "6 GB GPUs (deferred)").

## Planned CPU layout (May 2026 — final, replaces April 2026 MoE fleet)

**30B MoE fleet retired cluster-wide.** Operator decision: accuracy > speed; 30B
performance was unsatisfactory for general Q&A.

| Host | CPU role | Model | Notes |
|------|----------|-------|-------|
| **`gaming-c` gaming-worker-c** | **Sole CPU chat LLM** + primary embed | **`qwen3:32b`** Q5 target + `nomic-embed-text` | 64 GB DDR4; ~2–5 tok/s; accuracy-first |
| **`hub` hub** | **No chat LLM** (brain/LiteLLM/API only) | — | ~46 GiB; stop Ollama chat after `gaming-c` cutover |
| **`orchestrator` hub** | **No chat LLM** (gateway + GPU only) | — | 32 GB; stop Ollama after `gaming-c` cutover |
| **`gaming-b` gaming-worker-b** | **Reranker** + embed cold-standby | `BAAI/bge-reranker-v2-m3` + `nomic-embed-text` (stopped) | 64 GB; wired when RAG pipeline lands |

**Fallback when `gaming-c` down:** `frontier` (70B Petals GPU) — **not** MoE.

**Why `gaming-c` for dense 32B:** only fleet host with **64 GB RAM** and no brain / 32 GB
ceiling; beats MoE on Qwen creative/coding proxies per [MODEL_FIT_AUDIT.md](MODEL_FIT_AUDIT.md).
**Why `gaming-b` for reranker:** ample RAM but slower CPU (i7-11700 8c) — wrong box for
slow 32B inference; better used for tiny cross-encoder + embed cold-standby.

**Unchanged:** GPU tiers **3a** (Petals 70B) and **3b** (80B RPC).

**Rollout order:** `gaming-c` first (after `gaming-a` verified) → `gaming-b` → `hub` LiteLLM cutover → `orchestrator` last.

Operator detail: [deploy/cluster-members/gaming-worker-c/README.md](../deploy/cluster-members/gaming-worker-c/README.md),
[deploy/cluster-members/gaming-worker-b/README.md](../deploy/cluster-members/gaming-worker-b/README.md).

## Why Qwen3 (and why now)

In April 2026 the open-weights frontier on a ~46 GB / 5-node / 1 GbE rig
**IS the Qwen3 family**. Every non-Qwen model that would beat it in any
tier on this rig either:

- **Won't fit** — DeepSeek-V3/V3.1/R1 full (671B), Llama 4 Maverick (400B),
  GLM-4.5 full (355B), Qwen3-235B-A22B.
- **Ties on VRAM but loses on benchmarks** — Llama 4 Scout (109B MoE),
  Gemma 3 27B, Mistral Small 3 / Devstral, Command-R+, Phi-4.
- **Is itself a Qwen3 variant** — Qwen3-Coder-Next 80B-A3B (deferred to
  Phase 5 pending upstream RPC stability), Qwen3.5-35B-A3B (MoE).

Closest "could-replace" alternative: **GLM-4.5-Air** (106B / 12B MoE) on
agentic reasoning. Documented as a future fallback. Not default.

**SWE-bench-class scores** depend on **agent scaffold, tool parser, and
eval version** (see [SWE-bench](https://www.swebench.com/) and model-specific
reproduction notes). The **Qwen3-Coder blog** highlights **SWE-Bench-class**
results for the **480B** Coder flagship; the **30B-A3B** HF card does **not**
establish a single vendor SWE number comparable across scaffolds. Do **not**
treat undocumented “~40%” / “~70%” figures in old drafts as SSoT—use
[MODEL_FIT_AUDIT.md](MODEL_FIT_AUDIT.md) for **creator-published** proxies
(HumanEval / MBPP / LiveCodeBench / IFEval / Creative Writing v3) and
third-party leaderboards only when a **cited row + setup** is provided.

## Why a dual runtime (Petals + llama.cpp RPC)

Upstream Petals’ **PyPI** release is stale; this repo’s **`alfa-petals-ml-base`**
image installs **Petals from GitHub** with **`transformers` 4.43.x** so Llama 3.3
configs load (see [Dockerfile.ml-base](../deploy/petals/Dockerfile.ml-base)).
That band is still **below** the **Qwen team’s** documented floor for loading
Qwen3 checkpoints in Transformers (**`transformers>=4.51.0`** per
[Qwen Transformers doc](https://qwen.readthedocs.io/en/latest/inference/transformers.html)).

- **Petals stays** for tier **3a** frontier-chat with **`meta-llama/Llama-3.3-70B-Instruct`**
  (NF4 at workers). **Qwen3 dense checkpoints are not a drop-in** on this Petals
  stack without new upstream (or fork) work — see `SUPPORTED_MODELS` in
  [petals_gateway.py](../src/inference/petals_gateway.py).
- **llama.cpp RPC** serves tier **3b** **`Qwen3-Coder-Next-80B-A3B-Instruct`** (GGUF, e.g. Q4_K_M — file size per [Qwen/Qwen3-Coder-Next-GGUF](https://huggingface.co/Qwen/Qwen3-Coder-Next-GGUF)). Stack under
  [deploy/llamacpp-rpc/](../deploy/llamacpp-rpc/), pinned to a vetted
  `b-tag`; watch upstream MoE/RPC issues ([#17938](https://github.com/ggml-org/llama.cpp/issues/17938),
  [#18882](https://github.com/ggml-org/llama.cpp/issues/18882),
  [#19745](https://github.com/ggml-org/llama.cpp/issues/19745),
  [#20587](https://github.com/ggml-org/llama.cpp/issues/20587)) when bumping builds.

**Mutual exclusion (mandatory on GPU):** **Petals 70B (3a)** and **llama.cpp 80B (3b)** must **not** occupy the same **GPU** VRAM. When the operator (or product) selects **80B** mode, **stop Petals workers and related GPU deps** on those hosts; when selecting **70B** Petals mode, **stop** the **llama-server** coordinator and **all** **`rpc-server`** shards. Switching is **infrequent** by design. **CPU** Ollama **`qwen3:32b`** on **`gaming-c`** is **unaffected** — it does not use those dGPUs for tiers 0/1/2.

## Alternatives considered and rejected

- **Upgrade Petals to support Qwen3** — no upstream path. Would require
  forking, writing Qwen3 attention + MoE layer definitions, and
  maintaining a private fork indefinitely. Months of work; upstream
  community has moved on.
- **`b4rtaz/distributed-llama`** — actually supports Qwen3 MoE on
  commodity Ethernet. Rejected for: tensor-parallel requires power-of-2
  node counts (we have 5), less mature orchestration than llama.cpp,
  ecosystem gravity favors llama.cpp.
- **`exo-explore/exo`** — Apple-Silicon-first; off the golden path for
  an NVIDIA/Windows rig. Open issues on Qwen3 stability as of April 2026.
- **vLLM + Ray multi-node** — designed for ≥10 GbE / NVLink / IB. On
  1 GbE the PP / TP communication becomes the bottleneck and effective
  throughput drops by >1 order of magnitude. Re-evaluate if the LAN ever
  gets 10 GbE.
- **Retire Petals entirely** — simpler, but the **76 GB** GPU swarm for **70B-class**
  distributed chat is quality we'd be walking away from. Today that path is
  **Llama-3.3-70B-Instruct** on Petals, not Qwen3.
- **Single-host 80B on one GPU (skip RPC)** — **infeasible** for Q4-class **80B** weights on this cluster; **3b** is explicitly **multi-GPU RPC**. Tier 0/1/2 **CPU** MoE already covers “one box” coding latency; **3b** is the **distributed** coding tier.

## Files that changed in this migration

Code + config:
- [src/inference/petals_gateway.py](../src/inference/petals_gateway.py) —
  `SUPPORTED_MODELS` now whitelists `llama3.3-70b-instruct` and
  `llama3.1-8b-instruct` only.
- [deploy/litellm_config.yaml](../deploy/litellm_config.yaml) — full tier
  refresh; new `frontier-code` alias.
- [deploy/env.example](../deploy/env.example) — routing keys and model defaults (secret-free template);
  production values live in `deploy/.env` only.
- [env.example](../env.example) — repo-root defaults.
- [src/api/app.py](../src/api/app.py), [src/api/routers/chat.py](../src/api/routers/chat.py),
  [src/api/routers/guest.py](../src/api/routers/guest.py),
  [src/llm/client.py](../src/llm/client.py) — fallback default model path aligned with
  `DEFAULT_MODEL=qwen3.5:27b` (June 2026; `gaming-c` quality, `orchestrator` `qwen3.6:35b-a3b` speed).
- [deploy/petals/env.worker.example](../deploy/petals/env.worker.example)
  and active `.env.worker` on each node — `PETALS_MODEL` →
  `meta-llama/Llama-3.3-70B-Instruct`.
- [deploy/petals/docker-compose.worker.{yml,cpu.yml,blackwell.yml}](../deploy/petals/)
  and `docker-entrypoint-*.sh` — default `PETALS_MODEL` updated to match.
- [deploy/cluster-members/_common/pull-models.ps1](../deploy/cluster-members/_common/pull-models.ps1)
  and [pull-models.sh](../deploy/cluster-members/_common/pull-models.sh) —
  canonical Qwen3 pull list.

New stack:
- [deploy/llamacpp-rpc/](../deploy/llamacpp-rpc/) — full llama.cpp RPC
  compose + Dockerfile + fetch script.
- [docs/LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) — operator
  runbook.

Explicitly NOT changed (and why):
- Petals **install path**: `alfa-petals-ml-base` installs **Petals from GitHub**
  (`PETALS_GIT_REF`, default pinned SHA **`22afba6`** in `Dockerfile.ml-base`) with
  **transformers 4.43.x** for Llama 3.3. **Blackwell workers** use **`Dockerfile.petals-worker.gpu-blackwell`**
  (Petals **`main`** + torch **2.7 cu128** for sm_120 / hivemind compatibility). The old PyPI stack
  (`petals==2.2.0.post1`, `transformers<4.35`) **cannot** run `meta-llama/Llama-3.3-70B-Instruct`.
- Blackwell Dockerfile stack. CUDA 12.8 pattern reused by the new
  llama.cpp RPC Dockerfile.
- `hub` hub OS, Windows hosts, any hardware.

## Phase 5 — GPU frontier-code: Qwen3-Coder-Next 80B-A3B (active plan)

**Goal:** Remove **GPU** **llama.cpp RPC** for **`Qwen3-Coder-30B-A3B`** GGUF. **Tier 3b** becomes **`Qwen3-Coder-Next-80B-A3B-Instruct`** (e.g. **Q4_K_M**, ~48.4 GB on disk per [Qwen3-Coder-Next-GGUF](https://huggingface.co/Qwen/Qwen3-Coder-Next-GGUF)), sharded across **`rpc-server` on every Petals-capable GPU** (coordinator remains on **`gaming-b`** unless the operator moves it — see [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md)).

**Operational coupling:** **3a (Petals 70B)** stays **as today** (all swarm hosts / all GPUs) when **3b** is **off**. When **3b** is **on**, **Petals + its GPU deps on those boxes are down** — and the converse. **CPU** **`qwen3:32b`** on **`gaming-c`** for tiers **0/1/2** continues unchanged.

**6 GB cards (`apps` / `secondary`):** **Last** rollout step — confirm shard counts, coordinator context / layer split, and optional **`-dio` / `--fit`** behavior against upstream docs before adding them to the **80B** tensor pool ([LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) § "6 GB GPUs (deferred)").

**Quality expectation:** treat benchmark deltas as **hypothesis** until you re-measure on a **frozen** `llama.cpp` build and agent scaffold; use [MODEL_FIT_AUDIT.md](MODEL_FIT_AUDIT.md) for **vendor-cited** proxies only.

**Fallback:** If **3b** is down, clients use the tiers 0/1/2 chat model **`qwen3:32b`** on **`gaming-c`** (and, while `gaming-c` is pending, `frontier`/Petals) — **not** the retired **30B-A3B** MoE or the old **30B GGUF** RPC path.
