# G-rev72 operator runbook — Qwen2.5-72B dense (exclusive)

**Model:** **Qwen2.5-72B-Instruct** GGUF **Q5_K_M** (official
[Qwen/Qwen2.5-72B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-72B-Instruct-GGUF),
~**51.7 GB** weights). **Not** Llama-3.3-70B.

**Mode:** **Exclusive** on the RPC mesh — stops production **27B**. Same CPU
coordinator **`hub:31360`**. LiteLLM alias **`frontier`** (chat). Companion
coder exclusive mode: [GREV80_80B_OPERATOR.md](GREV80_80B_OPERATOR.md)
(`-InferenceMode Pool80`).

**Operator policy (2026-08-10):** **Q5_K_M** + **`CTX_SIZE=86016`** (YaRN
**2.625x**; shared with Pool80). Full-mesh `-ts` ~**62 GiB**; estimated
weights+KV ~**58.3 GiB** (~**+3.7 GiB** headroom). Watch `nvidia-smi` on tight
GPUs after load; roll back `CTX_SIZE=65536` if free less than ~800 MiB.

**VRAM / shards:** Pool72 has **dedicated** tensor-split budgets in
`deploy/llamacpp-rpc/pool72-shards.core.env` + `pool72-shards.gaming.env`
(not the inference hybrid-27B lists). Orchestrator selects them when
`-InferenceMode Pool72`. Core-only (~**29.5 GB** `-ts`) cannot fit ~41 GB
weights — require **full mesh** opt-in: **`gaming-c` / `gaming-a` / `gaming-b` / `secondary` /
`pool-opt-in`**. **`gaming-c`/`gaming-b`** are inference opt-in when not training; required for full
Pool72 mesh. Not concurrent 27B + 72B on the same GPU. Full mesh `-ts` sum ~**62 GB** (usable slices). Fit research:
[experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md](experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md).

**Slots:** **`PARALLEL=1`**, **`CTX_SIZE=86016`** (YaRN scale **2.625x** from
native 32k). Official model card: native **32,768**; longer context uses
[YaRN](https://huggingface.co/Qwen/Qwen2.5-72B-Instruct#processing-long-texts)
(`--rope-scaling yarn`, factor = `CTX_SIZE/32768`, `--yarn-orig-ctx 32768`).
Expect slower tok/s than 27B Q8. Cap for YaRN factor 4 is still **131072** if
you raise CTX later (reduces Q5 headroom).

**llama-server n_ctx cap (2026-08-10):** With YaRN argv alone, `/props` still
reported **`n_ctx=32768`** and start failed the GREV72 assert. Upstream
`llama-server` caps slot context to GGUF `context_length` unless metadata is
raised ([llama.cpp #17459](https://github.com/ggml-org/llama.cpp/issues/17459);
maintainer: `--override-kv …context_length=…`). Pool72 compose adds
`qwen2.context_length` + `qwen2.rope.scaling.*` overrides
([server README `--override-kv`](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md),
arch keys from [llama.cpp #10698](https://github.com/ggml-org/llama.cpp/pull/10698)).
Deploy asserts `/props` `n_ctx` == `CTX_SIZE` after health.

### Dense KV / share math (closed form)

Architecture ([HF config](https://huggingface.co/Qwen/Qwen2.5-72B-Instruct)):
`n_layer=80`, `n_kv_heads=8`, `head_dim=128` (8192/64). With **q4_0** KV
(~0.5 B/elem):

```text
KV_GiB ~= 2 * 80 * 8 * 128 * CTX * 0.5 / 1024^3
       ~= 80 KiB per token  (pool-wide)
```

| `CTX_SIZE` | KV (q4_0) | weights Q5 (~51.7) +KV | YaRN `ROPE_SCALE` |
|------------|-----------|------------------------|-------------------|
| 32768 | ~2.5 GiB | ~54.2 GiB | (none) |
| 65536 | ~5.0 GiB | ~56.7 GiB | 2 |
| **86016** (default) | ~6.6 GiB | ~**58.3 GiB** | **2.625** |
| 131072 | ~10.0 GiB | ~61.7 GiB | 4 |

Per-GPU estimate (llama.cpp `--tensor-split` proportions,
[multi-gpu.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md)):

```text
share_i ~= (weights + KV) * (ts_i / sum_ts) + ~1 GiB overhead
```

Recompute after editing shard files:

```powershell
python scripts/estimate-pool72-vram.py --ctx 131072
```

### Pool72 TENSOR_SPLIT (full mesh)

| Order | Host | Port | GPU | `ts` (usable) | Why vs inference |
|-------|------|------|-----|---------------|---------------|
| 1 | `inference` | 31356 | 3060 12 GB | **11** | same usable slice |
| 2 | `inference` | 31357 | **5060 8 GB** | **6.5** | was **9** (oversubscribed for 27B) |
| 3 | `gaming-a` | 31352 | 5060 8 GB | **5** | WDDM reserve |
| 4 | `gaming-c` | 31351 | 5070 12 GB | **9** | desktop reserve |
| 5 | `gaming-b` | 31358 | 5070 12 GB | **9** | desktop reserve |
| 6 | `orchestrator` | 31350 | 3060 12 GB | **9.5** | was **11** (WDDM) |
| 7 | `secondary` | 31355 | 1070 8 GB | **~5.5** (8×69%) | dense KV needs honest slice |
| 8 | `pool-opt-in` | 31354 | 1660S 6 GB | **~4.0** (6×67%) | was 6@70% |
| 9 | `hub` | 31353 | 3050 | **~2.5** (4×62%) | was 4@70% |

**Sum `ts` ≈ 62.0.** Estimated share+overhead @ **128k** (tightest first):

| GPU | est+oh GiB | Physical | Margin |
|-----|------------|----------|--------|
| `inference` 5060 | ~6.4 | 8 | ~1.6 |
| `gaming-a` 5060 | ~5.2 | 8 | ~2.8 (desktop uses rest) |
| `pool-opt-in` 1660S | ~4.3 | 6 | ~1.7 |
| `hub` 3050 | ~3.1 | **6 GB** | OK (~3 GiB free) |
| `inference`/`orchestrator` 3060 | ~8–9 | 12 | OK |
| `gaming-c`/`gaming-b` 5070 | ~8.5 | 12 | OK |

Baseline VRAM @ **32k** with **old inference `-ts`** (2026-08-09; 5060 oversubscribed):

| Host | GPU | Used MiB | Free MiB | Total |
|------|-----|----------|----------|-------|
| `orchestrator` | 3060 | ~8428 | ~3860 | 12288 |
| `inference` | **5060** | ~6264 | **~1444** | 8151 |
| `inference` | 3060 | ~8749 | ~3163 | 12288 |
| `gaming-a` | 5060 | ~5406 | ~2491 | 8151 |
| `pool-opt-in` | 1660S | ~3206 | ~2543 | 6144 |

After this rebalance + 128k default: re-measure all GPUs. If any card OOMs or
free < ~800 MiB, roll back CTX (not shards first):

```bash
# on hub before / inside start-pool72 write path:
sudo CTX_SIZE=65536 bash deploy/cluster-members/hub/write-grev72-pool-env.sh
```

Prefer changing the default in `write-grev72-pool-env.sh` + full orchestrator
cycle so every host stays on the same sheet of music.

**SSoT:** [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).
**Routine ops:** still only `Start-Stop-AlfaAi.ps1` — use **`-InferenceMode Pool72`**.
On **stop** after a Pool72 run, pass **`-InferenceMode Pool72`** so the active
shard list rebuilds from `pool72-shards.*` (host:port targeting); default stop
uses inference lists.

## Official references

| Topic | URL |
|-------|-----|
| Qwen2.5-72B Instruct | https://huggingface.co/Qwen/Qwen2.5-72B-Instruct |
| Official GGUF | https://huggingface.co/Qwen/Qwen2.5-72B-Instruct-GGUF |
| llama.cpp multi-GPU / tensor-split | https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md |
| llama.cpp KV / multi-GPU notes | https://github.com/ggml-org/llama.cpp/discussions/10068 |
| llama.cpp RPC | https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md |
| Hub seed | [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) |

## Hub artifact

| Field | Value |
|-------|-------|
| HF repo | `Qwen/Qwen2.5-72B-Instruct-GGUF` |
| Lead file | `qwen2.5-72b-instruct-q5_k_m-00001-of-00014.gguf` (14 shards total) |
| Hub path | `/mnt/HDDs/Alfa-AI/llama-cpp/models/` (+ promote all shards to SSD/NVMe) |
| Seed (`hub` only) | `sudo bash scripts/hub_hub_models.sh pull gguf72` |

Workers never download from the public internet ([hub-hub-first](../.cursor/rules/hub-hub-first.mdc)).

## Bring-up (operator)

1. **Seed** on `hub` (once): `pull gguf72`, then optional
   `sudo inference_MODEL_FILE=qwen2.5-72b-instruct-q4_k_m-00001-of-00012.gguf bash deploy/cluster-members/hub/promote-gguf-to-ssd.sh`
2. **Commit/push** repo changes from owning host; **pull** every clone.
3. **Stop** 27B: `Start-Stop-AlfaAi.ps1 stop` from `orchestrator`.
4. **Start exclusive 72B** with **all** opt-in hosts **Y**:

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start -InferenceMode Pool72 -GamingMode Flags -Include59 -Include219 -Include249 -Include248 -Include100
```

5. **Verify:** wait helper / coordinator `/health`; LiteLLM `frontier` smoke;
   `nvidia-smi` on every shard vs the est+oh table above.

## Tear-down back to 27B

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 stop -InferenceMode Pool72
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start
```

(Default start `-InferenceMode inference` rebuilds from `inference-shards.*`.)

## Guards (same as inference)

- **No** piecemeal shard/coordinator restarts while the coordinator is up.
- **No** hot-join/leave — change membership only via full stop + start.
- Self-test must pass before declaring green (`MODEL_ALIAS=qwen2.5-72b`).

## Scripts

| Script | Role |
|--------|------|
| `scripts/estimate-pool72-vram.py` | Closed-form weight+KV per `ts` |
| `scripts/hub_hub_models.sh pull gguf72` | Hub seed |
| `deploy/llamacpp-rpc/pool72-shards.core.env` | Always-on dense budgets |
| `deploy/llamacpp-rpc/pool72-shards.gaming.env` | Opt-in dense budgets |
| `deploy/cluster-members/hub/write-grev72-pool-env.sh` | `.env.rpc` for 72B (default CTX 131072) |
| `deploy/cluster-members/hub/switch-pool-72b.sh` | LiteLLM `frontier` + `litellm_config.pool72.yaml` |
| `deploy/cluster-members/hub/deploy-grev72-pool-coordinator.sh` | Coordinator load |
| `operator-cluster-111.sh start-pool72` | Called by orchestrator when `Pool72` |

Brain `deploy/.env` after `switch-pool-72b.sh`: `ALFA_INFERENCE_MODE=pool72`,
`LITELLM_CONFIG=litellm_config.pool72.yaml`. Admin Health uses that for
`active_pool` / inference_mode labels ([ADMIN_HEALTH_WEB_WORKFLOW.md](ADMIN_HEALTH_WEB_WORKFLOW.md)).

### Online research missions (not MCP)

Pool72 is the **inference backend** for agent tool-calling; orchestration is the
existing Missions loop + SearXNG `web_search` ([AGENT_RESEARCH_TOOLS.md](AGENT_RESEARCH_TOOLS.md)).

| Env (brain `deploy/.env`) | Pool72 value |
|---------------------------|--------------|
| `ALFA_AI_AGENT_MODEL` | `frontier` |
| `ALFA_AI_WEB_SEARCH_ENABLED` | `1` (after SearXNG up) |
| `ALFA_AI_SEARXNG_URL` | `http://alfa-searxng:8080` |

**Enable (`hub`):** `bash scripts/operator-pool72-research-enable.sh`  
**Verify:** `bash scripts/verify-pool72-research-smoke.sh`  
Restore `ALFA_AI_AGENT_MODEL=frontier-code` when switching back to inference.

MCP and Cursor IDE skills are **not** required for online research on Pool72.

## Related

- Production 27B: [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md)
- Cluster start/stop: [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md)
- llama.cpp RPC: [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md)
