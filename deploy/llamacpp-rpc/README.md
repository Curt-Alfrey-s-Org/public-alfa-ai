# llama.cpp RPC -- ALFa AI four-host frontier pool

Distributed **Qwen3** GGUF inference across the **always-on** hosts
**`orchestrator` / `apps` / `hub` / `inference`**, using **`llama.cpp`** `rpc-server` shards
plus a **`llama-server`** CPU coordinator on **`hub`**.

**SSoT:** [`.cursor/plans/FOUR_HOST_FRONTIER_POOL.md`](../../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md)
(models, ports, phases). **inference opt-in:** **`gaming-a` / `gaming-c` / `gaming-b` / `secondary` / `pool-opt-in`**
-- never required for core green. **Train lock** blocks inference on **`gaming-c`** / **`gaming-b`**
(and **`gaming-a`** when training). Same ports serve Pool72/80 when selected -- not
concurrent 27B + dense 72B/80B on one GPU.

**Production 27B runbook:** [GREV27_27B_OPERATOR.md](../../docs/GREV27_27B_OPERATOR.md).

**Mutually exclusive with Ollama on the same GPU:** stop Ollama GPU workloads before
bringing up RPC backends on that GPU (and the reverse). See
[`../../docs/LLAMACPP_RPC_OPERATOR.md`](../../docs/LLAMACPP_RPC_OPERATOR.md).

## Coordinator (`hub:31360`)

The OpenAI-compatible HTTP endpoint for **Phase H** is **`hub:31360`** (CPU
coordinator, `CUDA_VISIBLE_DEVICES=` empty). LiteLLM on `hub` dials
`http://127.0.0.1:31360/v1` for **`frontier-code`** and **`frontier`** (27B pool; same backend today).

| Profile | Alias | Model | Default quant |
|---------|-------|-------|---------------|
| Code27 (production) | `qwen3.6-27b` | Qwen3.6-27B | UD-Q4_K_XL |
| Speed (when 27B stopped) | `qwen3.6-35b-a3b` | Qwen3.6-35B-A3B | UD-Q4_K_XL |
| Code (optional) | `qwen3-coder-next-80b-a3b` | Qwen3-Coder-Next-80B-A3B | Q4_K_M |
| Chat (future) | `qwen3.5-122b-a10b` | Qwen3.5-122B-A10B | Q3_K_M |

Compose: `docker-compose.rpc-main.grev27-pool-coordinator.yml` + `.env.rpc` on **`hub` only**.
Env template: `.env.rpc.example` (commented **CHAT** and **CODE** profiles).

## Primary-set port table (Phase H — 27B pool)

| Host / GPU | Role | Port |
|------------|------|------|
| `inference` RTX 3060 | rpc-server backend (shard 1) | **31356** |
| `inference` RTX 5060 | rpc-server backend (shard 2) | **31357** |
| `orchestrator` RTX 3060 | rpc-server backend (shard 3) | **31350** |
| `hub` RTX 3050 | rpc-server backend (shard 4) | **31353** |
| `hub` CPU | coordinator `llama-server` | **31360** |

**Retired:** `inference:31358` local dual-GPU 27B; coordinator on `inference`/`orchestrator`; `orchestrator` `:31355`
(second GPU removed 2026-06-21).

Opportunistic hosts (inference opt-in at each `Start-Stop-AlfaAi.ps1 start`):
`gaming-a` **31352**, `gaming-c` **31351**, `gaming-b` **31358**, `secondary` **31355**, `pool-opt-in` **31354**
(`inference-shards.gaming.env`; Pool72/80 reuse same ports when that mode is selected).

Full doc: [`../../docs/PORT_ASSIGNMENTS.md`](../../docs/PORT_ASSIGNMENTS.md).

## GPU shard vs CPU-RAM shard

Each **`rpc-server`** backend advertises either **GPU VRAM** or **host RAM**:

- **GPU shard (default):** set `CUDA_VISIBLE_DEVICES=0` (or `1` on the second GPU).
  Use `docker-compose.rpc-server.yml` on single-GPU hosts, or
  `docker-compose.rpc-server.dual-gpu-148.yml` on `inference` (RTX 5060 `:31357` + RTX 3060 `:31356`),
  or `docker-compose.rpc-serverhub-gpu3050.yml` on `hub` (RTX 3050 `:31353`).
- **CPU-RAM shard:** set `CUDA_VISIBLE_DEVICES=` **empty** in `.env.rpc` so
  `rpc-server` spills MoE weights to CPU instead of a GPU card.

Same image (`alfa-llamacpp-rpc:cuda128`); no separate CPU-only Dockerfile unless
proven necessary.

## Chat vs code switch (one model at a time)

**27B** and **35B** share **`hub:31360`** — only one coordinator profile at a time.
Use `switch-pool-27b.sh` / `switch-pool-35b.sh` on `hub`.

**Stop one, start the other:**

1. On **`hub`**, stop the coordinator:
   `docker compose --env-file .env.rpc -f docker-compose.rpc-main.grev27-pool-coordinator.yml down`
2. Edit **`.env.rpc`**: uncomment the target profile from `.env.rpc.example`,
   set `MODEL_FILE` to the hub-relative GGUF path,
   set `MODEL_ALIAS` and `RPC_BACKENDS` for that profile.
3. Start the coordinator:
   `docker compose --env-file .env.rpc -f docker-compose.rpc-main.grev27-pool-coordinator.yml up -d`
4. Poll health (do not one-shot curl during `(health: starting)`):
   `Wait-AlfaHttpPoll` / `wait-http.sh` on `http://127.0.0.1:31360/health`

**27B pool** `RPC_BACKENDS` (from `inference-shards.env`):
`orchestrator,orchestrator,orchestrator,hub`

Backends can stay up across the switch; only the coordinator GGUF and
`RPC_BACKENDS` list change.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile.rpc-cuda128` | Single image (`GGML_CUDA` + `GGML_RPC`, sm_75/80/86/120) |
| `Dockerfile.rpc-cuda128-pascal` | Pascal + cluster SMs (`61;75;80;86;120`) for gpu-248 `secondary` GTX 1070 |
| `docker-compose.rpc-server.yml` | One `rpc-server` per single-GPU backend |
| `docker-compose.rpc-server.dual-gpu-148.yml` | `inference` RTX 5060 `:31357` + RTX 3060 `:31356` |
| `docker-compose.rpc-serverhub-gpu3050.yml` | `hub` RTX 3050 `:31353` |
| `docker-compose.rpc-server.dual-gpu-93.yml` | `orchestrator` opportunistic 2x3060 (retired — 1 GPU only) |
| `docker-compose.rpc-main.grev27-pool-coordinator.yml` | Coordinator `llama-server` on `hub` |
| `.env.rpc.example` | Per-host env + commented CHAT/CODE profiles |
| `inference-shards.env` | Canonical 27B shard list + tensor-split |
| `scripts/fetch-qwen3-coder.sh` | Hub-only GGUF fetch (`hub`); chat/code/agentic profiles |

## Quick start

Full runbook: [`../../docs/GREV27_27B_OPERATOR.md`](../../docs/GREV27_27B_OPERATOR.md).

1. **Stage GGUFs on `hub` hub only** (`scripts/fetch-qwen3-coder.sh` with
   `PROFILE=chat|code|agentic`; see `docs/HUB_ARTIFACTS.md`). Workers mount
   `/mnt/cluster/llama-cpp/models/` (NFS) or equivalent -- never re-download
   on a worker.
2. **Backends** -- bring up `rpc-server` on each host (ports above).
3. **Coordinator** -- on **`hub`**, set **27B pool** profile in `.env.rpc`, start
   `docker-compose.rpc-main.grev27-pool-coordinator.yml`.
4. **LiteLLM** -- point `LLAMACPP_CODE27_URL` at `http://127.0.0.1:31360/v1`
   (owned by `deploy/litellm_config.yaml`).

## Build / pin

When bumping **`llama.cpp`**, re-vet MoE + RPC issues in
[`../../docs/LLAMACPP_RPC_OPERATOR.md`](../../docs/LLAMACPP_RPC_OPERATOR.md) and
[`../../docs/QWEN3_MIGRATION.md`](../../docs/QWEN3_MIGRATION.md).