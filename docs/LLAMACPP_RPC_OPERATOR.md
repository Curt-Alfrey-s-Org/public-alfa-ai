# llama.cpp RPC operator runbook — frontier pool

> **Phase H (2026-08):** **27B inference** — CPU coordinator **`hub:31360`**;
> **always-on shards:** `inference:31356`/`:31357`, `orchestrator:31350`, `hub:31353`
> (`TENSOR_SPLIT` **12,8,10,5** = **35.0 GB**). **inference opt-in at start:**
> `gaming-a:31352`, `gaming-c:31351`, `gaming-b:31358`, `secondary:31355`, `pool-opt-in:31354`
> (`gaming-a`+`secondary`+`pool-opt-in` ≈ **52 GB** `-ts`; all five ≈ **70 GB** `-ts`).
> **`PARALLEL=5`**, **`CTX_SIZE=262144`**.
> **35B MoE retired** (optional revive via `switch-pool-35b.sh` only).
> **Production runbook:** [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md).
> Gaming join: [inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md).
> SSoT: [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).

Operator guide for the frontier pool: a distributed **`llama.cpp`** pipeline
(coordinator `llama-server` + GPU `rpc-server` backends + CPU/RAM offload).

**Not in scope here:** **CPU** chat Ollama pool (opportunistic, gaming hosts).

See also:

- [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) — **production** 27B RPC pool (Phase H).
- [inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md) — inference opt-in join (`gaming-a`/`gaming-c`/`gaming-b`/`secondary`/`pool-opt-in`).
- [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md) — tier matrix.
- [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md) — cluster architecture.
- [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) — canonical ports (gaming RPC included).
- [`deploy/llamacpp-rpc/`](../deploy/llamacpp-rpc/) — Dockerfile, compose, `.env.rpc.example`, fetch scripts.

## Phase H — 27B RPC pool (production `frontier-code`)

**Active path.** Full runbook: [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md).

| Item | Value |
|------|-------|
| Model | `unsloth/Qwen3.8-27B-GGUF` / `Qwen3.8-27B-Q8_0.gguf` production (~29 GB); 3.6 Q8 + Q4_K_XL rollback on hub |
| Coordinator | `hub` CPU `:31360` (`CUDA_VISIBLE_DEVICES=` empty) |
| Always-on shards | `inference` 3060 `:31356` + 5060 `:31357`; `orchestrator` 3060 `:31350`; `hub` 3050 `:31353` |
| inference opt-in shards | `gaming-a` 5060 `:31352`; `gaming-c` 5070 `:31351`; `gaming-b` 5070 `:31358`; `secondary` 1070 `:31355`; `pool-opt-in` 1660S `:31354` |
| Pool72/80 dense mesh | Same ports; exclusive load (not concurrent 27B + 72B/80B on one GPU) |
| Concurrency | `PARALLEL=5` (52428 tokens/slot at `CTX_SIZE=262144`; Qwen3.8 native max; 2 user + 3 auto) |
| Engine | `llama-server` coordinator + `rpc-server` GPU backends |
| LiteLLM | `LLAMACPP_CODE27_URL=http://127.0.0.1:31360/v1` |
| Hub verify | `sudo bash scripts/hub_hub_models.sh verify gguf27` |
| Deploy | `Start-Stop-AlfaAi.ps1` from `orchestrator` only (orchestrator); no piecemeal shards |

**Retired for 27B:** local dual-GPU `inference:31358`; coordinator on `inference`/`orchestrator`; `orchestrator` `:31355` as always-on.

## Security and networking (mandatory — audit RPC-002 / CROSS-RULE-005)

Upstream **[llama.cpp `tools/rpc/README.md`](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)** states (emphasis in original):

> this example and the RPC backend are currently in a proof-of-concept development stage. As such, the functionality is fragile and **insecure**. **Never run the RPC server on an open network or in a sensitive environment!**

That applies to **every `rpc-server` shard** in this cluster. The **`llama-server`** coordinator exposes an OpenAI-compatible HTTP API on **`MAIN_PORT`** (default **`31360`**); treat it as **equally sensitive**: there is no production-grade auth boundary comparable to a full API gateway unless **you** add one.

**Why we still bind `0.0.0.0`:** shards listen on **`0.0.0.0:${RPC_PORT}`** (`network_mode: host` on Linux, or published ports on Docker Desktop for `orchestrator`) so the coordinator on **`gaming-b`** can dial **`RPC_BACKENDS`** across the LAN. Binding loopback-only would break cross-host sharding. **Defense in depth is host firewall + VLAN segmentation**, not “trust the LAN.”

**Operator requirements before any RPC traffic:**

1. **Restrict inbound TCP** on every host that runs **`rpc-server`** or the coordinator to **trusted sources only** (recommended: **`orchestrator/24`** or your management VLAN — adjust CIDR to match reality).
2. **Ports to lock down** (canonical list: [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) § llama.cpp RPC): shard backends **`31350`**, **`31353`**, **`31356`**, **`31357`**; coordinator **`31360`** on **`hub`**. Allow **coordinator → each shard** and **brain `hub` → coordinator `:31360`** for LiteLLM `frontier-code`; **deny WAN / guest Wi‑Fi / ** unless you explicitly design for that.
3. **`orchestrator` (Docker Desktop):** **`31350`** is published to **all interfaces** by compose — **Windows Defender Firewall** inbound rules must scope source IP to the LAN (or coordinator + shard IPs only). **`:31355` retired** (second GPU removed 2026-06-21).

**Linux — generic `ufw` pattern** (replace **`LAN_CIDR`** if not `orchestrator/24`; run on each shard host for **that host's `RPC_PORT`**, and on **`gaming-b`** for **`31360`**):

```bash
LAN_CIDR=orchestrator/24
# Example — shard on hub (RPC_PORT=31353). Repeat with the correct port per host.
sudo ufw allow from "$LAN_CIDR" to any port 31353 proto tcp comment 'llamacpp rpc-server (audit RPC-002)'
# Coordinator (gaming-b) — LiteLLM on brain hub and LAN operators reach HTTP API
sudo ufw allow from "$LAN_CIDR" to any port 31360 proto tcp comment 'llamacpp coordinator HTTP (audit RPC-002)'
# Confirm rule ordering after edits (specific allows before blanket denies): sudo ufw status numbered
```

**hub Scale:** there is no stock **`ufw`** — use **Network → Firewall** with the same **LAN-only** semantics for the NIC that faces your trusted subnet.

**Coordinator-only allowlist (tighter than LAN-wide):** a stray client that opens a
shard RPC port and sends non-HELLO bytes (port scan, monitoring probe, a second
coordinator) can **wedge** that shard (`Expected HELLO command, update client`) and
then crash the real coordinator on its next decode. Restrict each shard port to the
**coordinator IP + loopback only**:

```bash
sudo COORDINATOR_IP=hub RPC_PORTS="31356 31357" \
  bash deploy/cluster-members/_common/restrict-rpc-shard-firewall.sh
```

See [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) § "Crash prevention: readiness gating, restart policy, isolation" for the full readiness-gate + restart-policy + ordered-recovery design.

**Windows 11:** **Windows Defender Firewall → Advanced settings → Inbound Rules**: allow **TCP `31350`** (and Petals **`31330`/`31340`** if applicable) **only** from **`orchestrator/24`** (or narrower).

Document completed rules in your host runbook; backlog **#34** tracks folding these into workspace **`port-assignment-rules.mdc`** as Rule 3 LAN exceptions.

## Topology (target — all swarm GPUs)

```
LiteLLM (hub:8413)
      │  frontier-code alias
      ▼
llama-server (hub:31360) ── CPU coordinator + HTTP endpoint
      │
      ├── rpc-server shards: inference (3060 :31356, 5060 :31357),
      │   orchestrator (3060 :31350), hub (3050 :31353)
      └── (inference opt-in) gaming-a / gaming-c / gaming-b / secondary / pool-opt-in — see § gaming-host rollout
```

**Shard list:** one **`rpc-server`** binds **one** GPU per compose stack (see
`inference-shards.env`). **Coordinator** stays on **`hub:31360`** (Phase H); it needs
the GGUF on hub NFS and must list **every** backend in **`RPC_BACKENDS`**.

**VRAM:** **80B** Q4_K_M **weights alone** are **larger** than the old **30B** path;
the **entire** **~76 GB** Petals pool (or a deliberate subset) backs **3b**. **6 GB**
nodes are **out** of the first cut (see below).

## Mutual exclusion with Petals (tier 3a) — mandatory

**Petals** (**Llama-3.3-70B**) and this stack **cannot** share **GPU** VRAM.

**When enabling `frontier-code` (80B):**

1. On **each** host that runs **Petals workers** on GPUs used for **3b**, stop the
   **Petals worker** compose (and any GPU deps you use with it) **before** starting
   **`rpc-server`** / **`llama-server`** on those GPUs.
2. Start **all** **`rpc-server`** shards, then the **coordinator**.

**When reverting to Petals (70B):**

1. Stop **`llama-server`** on **`gaming-b`** (or coordinator host).
2. Stop **all** **`rpc-server`** containers.
3. Start **Petals** workers again.

**CPU** chat (`qwen3.5:27b` on `gaming-c` + `qwen3.6:35b-a3b` on `orchestrator`) does **not** use those dGPUs for tiers 0/1/2 — leave it **running**
unless you are doing host maintenance.

Infrequent switching is expected; document your host-local **compose** names so
the sequence is repeatable.

## Switch chat <-> code (scenario 2 -- coordinator on `orchestrator:31360`)

The GPU pool loads **one frontier GGUF at a time**. LiteLLM keeps both aliases
(`frontier` and `frontier-code`); only the coordinator **`MODEL_FILE`** /
**`MODEL_ALIAS`** / **`RPC_BACKENDS`** change.

| Profile | Alias | GGUF | RPC_BACKENDS (typical) | N_GPU_LAYERS |
|---------|-------|------|------------------------|--------------|
| **Code** | `qwen3-coder-next-80b-a3b` | Q4_K_M shard-1 under `Qwen3-Coder-Next-Q4_K_M/` | full pool (`orchestrator`, `inference` x2, `hub`; + gaming hosts when up) | **999** |
| **Code27** | `qwen3.6-27b` | `Qwen3.6-27B-Q4_K_M.gguf` | **`hub:31353` + `apps:31354` + `inference:31357`** (3060s on Ollama 35B; largest VRAM first) | **999** + **`--tensor-split 4,3,3`** + **`--fit off`** |
| **Chat** (future) | `qwen3.5-122b-a10b` | Q3_K_M shard-1 under `Q3_K_M/` | all shards (`orchestrator`, `inference` x2, `hub`) | **0** (MoE params_fit) |

### Code27 + Phase G 35B: CPU coordinator on `orchestrator` (mandatory)

Phase G runs **`qwen3.6:35b-a3b` Ollama on `orchestrator` + `inference` RTX 3060** while Code27
is optional. The coordinator process stays on **`orchestrator:31360`**, but it must **not**
bind the local **3060** for 27B weights.

**Upstream (official):**

- [tools/rpc/README.md](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md) — weights/KV split across visible local GPUs **and** RPC backends.
- [ggml-org/llama.cpp#11807](https://github.com/ggml-org/llama.cpp/issues/11807) — **`-ngl 0` disables GPU/RPC offload**; do not use for dense RPC models.
- [Discussion #18049](https://github.com/ggml-org/llama.cpp/discussions/18049) — **`--fit on`** rebalance when the coordinator has **no local GPU** (CPU-only orchestrator).
- [docs/multi-gpu.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md) — hide local GPUs with **`CUDA_VISIBLE_DEVICES=`** (empty) so only RPC devices receive layers.

**Cluster Code27 profile (`.env.rpc` on `orchestrator`):**

```text
CUDA_VISIBLE_DEVICES=
RPC_BACKENDS=hub,apps,orchestrator
CTX_SIZE=8192
N_GPU_LAYERS=999
TENSOR_SPLIT=4,3,3
CACHE_TYPE_K=q4_0
CACHE_TYPE_V=q4_0
MODELS_DIR=/home/operator/alfa-ai-cache/llama-cpp/models
CACHE_REUSE=256
```

Do **not** use **`--fit on`** for Code27 -- the probe loop is slow and can OOM `inference`
3050, spilling weights to `orchestrator` CPU. Use **`--tensor-split`** + **`--fit off`** via
**`docker-compose.rpc-main.code27-cpu.yml`**. Coordinator GGUF on WSL ext4; shards use
**`-c`** cache; coordinator uses **`--no-mmap`** ([#19745](https://github.com/ggml-org/llama.cpp/issues/19745)).

**Do not curl rpc-server ports** — they speak RPC `HELLO`, not HTTP. Use `nc -zv host port`
for reachability only ([tools/rpc/README.md](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)).

**CUDA graphs on rpc-server:** set `GGML_CUDA_DISABLE_GRAPHS=1` on every shard compose overlay
(mitigates unbounded graph cache / accept-queue wedge during RPC load —
[issue #20315](https://github.com/ggml-org/llama.cpp/issues/20315)). Base
`docker-compose.rpc-server.yml` and `inference-gpu3060` include this env; verify custom overlays do too.

**Compose overlays:** `deploy-llamacpp-rpc-coordinator.ps1` appends
`docker-compose.rpc-main.cpu-coordinator.yml` (empty `CUDA_VISIBLE_DEVICES`, no NVIDIA
reservation) and `docker-compose.rpc-main.code27-cpu.yml` (`--tensor-split`, `--fit off`,
`--no-mmap`, `N_GPU_LAYERS=999`). Shards use `docker-compose.rpc-server.cache.yml` (`-c`).

**Deploy guards:** `deploy-llamacpp-rpc-coordinator.ps1 -Profile Code27` runs
`Test-Code27LiteLLMProbeGuard.ps1` (blocks if LiteLLM on `hub:8413` is up or coordinator
logs show `hub` POST spam). Stop `sudo docker stop alfa-ai-litellm` on `hub` before first
load; `-SkipLiteLLMGuard` only when LiteLLM is confirmed stopped. After deploy,
`report-code27-vram-budget.ps1` prints per-shard weights vs 8+6+6 GB pool budget.

**Verify after deploy:** `nvidia-smi` on `orchestrator` — **3060 VRAM** should reflect
**Ollama 35B only**, not ~7 GiB from `llama-server`. Coordinator logs must show
**no `CUDA0` weight buffer**; only `RPC0[...]` / `RPC1[...]` / `RPC2[...]` shards.

**Hard rule (Code27 + Phase G):** **no 27B weight blocks on `orchestrator` GPU or CPU.**
The `orchestrator` host orchestrates only (`CUDA_VISIBLE_DEVICES=` empty). All tensor
weights must fit on RPC shards (`hub` / `apps` / `inference` 3050). If `--fit` would
spill to `CPU_Mapped` / `CPU_REPACK` on the coordinator, **do not accept the load**
— free/fix RPC shards (see `inference` `docker-compose.rpc-serverinference-code27.yml`) and
redeploy. `verify-code27-no-local-weights.ps1` enforces this after health OK.

**Mutual exclusion:** **Code (80B)** and **Chat (122B)** profiles still use
`orchestrator:31350` / `inference:31356` GPU shards — stop Ollama 35B and re-enable those
rpc-servers before switching away from Code27.

**Before switching:** confirm the target GGUF is in **`MODELS_DIR`** on `orchestrator`
(local cache `C:\alfa-ai-cache\llama-cpp\models` in WSL, or NFS). Hub path:
`/mnt/cluster/llama-cpp/models/` (see Phase A in
[FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md)).

### From `orchestrator` (PowerShell as `operator`)

**1. Stop the coordinator** (shards stay up):

```powershell
wsl -d Ubuntu bash -lc 'cd /mnt/c/Users/operator/alfa-ai/deploy/llamacpp-rpc && docker compose --env-file .env.rpc -f docker-compose.rpc-main.yml -f docker-compose.rpc-main.wsl-93.yml down'
```

**2. Apply profile** (automated -- preferred):

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\switch-coordinator-profile.ps1 -Profile Code
```

Or edit `deploy\llamacpp-rpc\.env.rpc` manually using the **CODE** block in
`deploy/llamacpp-rpc/.env.rpc.example`, then:

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\deploy-llamacpp-rpc-coordinator.ps1 -Profile Code
```

**3. Acceptance (direct coordinator):**

```powershell
curl.exe -fsS --max-time 600 -H "Authorization: Bearer change-me" http://127.0.0.1:31360/v1/models
curl.exe -fsS --max-time 600 -X POST http://127.0.0.1:31360/v1/chat/completions -H "Authorization: Bearer change-me" -H "Content-Type: application/json" -d "{\"model\":\"qwen3-coder-next-80b-a3b\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK in one word.\"}],\"max_tokens\":8}"
```

**4. Via LiteLLM on `hub`** (after coordinator is healthy):

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && set -a && . deploy/.env && set +a
curl -fsS --max-time 600 -X POST http://127.0.0.1:8413/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"frontier-code","messages":[{"role":"user","content":"Say OK in one word."}],"max_tokens":8}'
```

**5. Switch back to chat** (production default):

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\switch-coordinator-profile.ps1 -Profile Chat
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\deploy-llamacpp-rpc-coordinator.ps1 -Profile Chat
```

Expect **2-5 minutes** of `frontier` / `frontier-code` downtime while the
coordinator reloads. **`rpc-server` backends do not restart** for a profile swap.

## Cluster member one-shots (operator)

| Host | Script |
|------|--------|
| `hub` hub | `deploy/cluster-members/hub/llamacpp-verify-gguf.sh` (hub check); `deploy-llamacpp-rpc-shard.sh` (rpc-server :31353) |
| `orchestrator` Win11 | `deploy/cluster-members/orchestrator/deploy-llamacpp-rpc.ps1` (dual shard) |
| `gaming-b` Win11 | `deploy/cluster-members/gaming-worker-b/deploy-llamacpp-rpc.ps1` (coordinator) |
| `gaming-c` / `gaming-a` | `deploy-llamacpp-rpc.ps1` in each member folder (single shard) |
| `apps` / `secondary` (6 GB) | `llamacpp-rpc-deferred.sh` — do not enable until § "6 GB GPUs" is satisfied |

Each folder has `.env.rpc.example` → copy to `deploy/llamacpp-rpc/.env.rpc` (scripts copy on first run where noted).

## Files

Single source of truth: [`deploy/llamacpp-rpc/`](../deploy/llamacpp-rpc/).

| File | Role |
|------|------|
| `Dockerfile.rpc-cuda128` | Builds `alfa-llamacpp-rpc:cuda128` — single image for coordinator **and** RPC shard. Pinned to upstream `llama.cpp` `b10355` with `GGML_CUDA=ON`, `GGML_RPC=ON`, `CMAKE_CUDA_ARCHITECTURES="75;80;86;120"`. Includes **`qwen3next`**. Upstream binary is **`ggml-rpc-server`** ([b9824](https://github.com/ggml-org/llama.cpp/releases/tag/b9824)); image also provides `/usr/local/bin/rpc-server` symlink for existing compose. Stay on this pin until a planned hub rebuild. The next **stable** candidate is semver [v0.5.0](https://github.com/ggml-org/llama.cpp/releases/tag/v0.5.0) (RPC protocol major v7 — coordinator and every shard together). Do not track nightly `bNNNN` tags ([STABLE_RELEASES.md](../STABLE_RELEASES.md)). |
| `docker-compose.rpc-server.yml` | Launches `rpc-server` with separate argv tokens: `--host`, `0.0.0.0`, `--port`, `$RPC_PORT` (pinned `b7186` has no `--mem`; VRAM comes from the device). `network_mode: host`, reserves one GPU. |
| `docker-compose.rpc-main.yml` | Launches `llama-server` coordinator with `--rpc $RPC_BACKENDS`, `--model`, `--ctx-size`, `--n-gpu-layers`, `--api-key`. Exposes `$MAIN_PORT` HTTP. |
| `run-llama-server-coordinator.sh` | Pool coordinator argv (27B/72B/80B overlays). Includes official `--metrics` so Prometheus can scrape `GET /metrics` ([llama-server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)). Grafana: [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md). |
| `docker-compose.rpc-main.cpu-coordinator.yml` | Code27 overlay: empty `CUDA_VISIBLE_DEVICES`, no NVIDIA reservation (3060 free for Ollama 35B). |
| `docker-compose.rpc-main.code27-cpu.yml` | Code27 CPU coordinator: `--fit on`, no pinned `-ngl 999` (params_fit across RPC only). |
| `.env.rpc.example` | Per-host template. Copy to `.env.rpc` on each node and fill in the values for that node's role. |
| `scripts/fetch-qwen3-coder.sh` | Legacy helper for **30B** GGUF (drop from **GPU** tier after 80B cutover). Stage **80B** from [Qwen/Qwen3-Coder-Next-GGUF](https://huggingface.co/Qwen/Qwen3-Coder-Next-GGUF) on the hub per [SOURCE_OF_TRUTH_AND_SYNC.md](SOURCE_OF_TRUTH_AND_SYNC.md). |

## First-time bring-up

### Step 1 — pre-stage the GGUF weights

Weights live on hub (cold) and are read by the coordinator on `gaming-b`.
Use the helper:

Stage **Qwen3-Coder-Next** **Q4_K_M** weights: Hugging Face ships **four** GGUF shards under
`Qwen3-Coder-Next-Q4_K_M/` (not one monolithic file). On the hub (**`hub`** only, per
[HUB_ARTIFACTS.md](HUB_ARTIFACTS.md)):

```bash
sudo bash /path/to/alfa-ai/scripts/hub_hub_models.sh pull gguf
# or: cd deploy/llamacpp-rpc && ./scripts/fetch-qwen3-coder.sh
# with MODELS_DIR=/mnt/HDDs/Alfa-AI/llama-cpp/models
```

**`MODEL_FILE`** for `llama-server` must be the **first** shard:
`Qwen3-Coder-Next-Q4_K_M/Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf` (see `deploy/llamacpp-rpc/.env.rpc.example`).
Workers **read** over NFS — no per-member HF download.

The shard nodes **do not need the GGUF** — they are pure tensor backends
and load whatever the coordinator streams them. Only the coordinator
needs the file on local or NFS-mounted disk.

### Step 2 — image on the hub, workers load (no per-host rebuild)

**Policy:** One host (prefer **`hub`** or a designated builder) produces
`alfa-llamacpp-rpc:cuda128` once. Other hosts **`docker load`** a tarball from
`\\hub\temp\cluster_members\_common\docker-images\` (or equivalent hub
path) — see [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) and
`scripts/publish-built-image-to-hub.sh`. Member **`deploy-llamacpp-rpc.ps1`**
runs **`docker compose up -d --no-build`** when that image already exists locally.

**If you must build:** stage **`vendor/llama.cpp.tar.gz`** on the hub once
(`scripts/pack-llamacpp-vendor-tarball-on-hub.sh` on `hub`), then members run
`deploy/cluster-members/_common/sync-llamacpp-vendor-from-hub.*` (also invoked
from **`deploy-llamacpp-rpc.ps1`**) so the Dockerfile does **not** hit GitHub.
`configure-docker-mirror.ps1` points Docker at **`hub`** for
**`FROM nvidia/cuda`**. Prefer publishing the **built image** tarball for
workers; **`apt-get`** in base layers is cached after the first build.

### Step 3 — start every `rpc-server` backend

Order does not matter; the coordinator retries until each backend is
reachable. Bring up **all** planned shards (see topology); **exclude** **6 GB**
GPUs until § "6 GB GPUs" is satisfied.

Repeat on **every** GPU that participates (unique **`RPC_PORT`** + **`CUDA_VISIBLE_DEVICES`**
per stack). **`orchestrator`**: run **two** `rpc-server` stacks — **one per 3060**. **`hub`**:
one stack on the **5060** (after Petals is stopped for **3b** mode). **`gaming-b`**:
coordinator uses the **5070**; you can still run a **local** `rpc-server` on the
same card **only** if your compose layout separates processes cleanly — most
operators use **`gaming-b`** GPU for the coordinator only and shards on other boxes.

```powershell
# Example — orchestrator GPU 0 (adjust paths; second GPU = second compose + different RPC_PORT):
cd C:\alfa-ai-worker\llamacpp-rpc
docker compose --env-file .env.rpc -f docker-compose.rpc-server.yml up -d
```

```bash
# Example — Linux member (e.g. gaming-c, gaming-a, hub): same pattern, unique RPC_PORT per GPU.
cd ~/alfa-ai/deploy/llamacpp-rpc
docker compose --env-file .env.rpc -f docker-compose.rpc-server.yml up -d
```

Verify each backend is listening (ports from your **`RPC_BACKENDS`**):

```bash
ss -tln | grep 3135      # expect one LISTEN per shard
docker logs llamacpp-rpc-server 2>&1 | tail -20
# → "Starting RPC server on 0.0.0.0:<RPC_PORT>, backend memory: ... MB"
```

### Step 4 — start the coordinator on `gaming-b`

```bash
ssh gaming-worker-b@orchestrator
cd /home/gaming-worker-b/alfa-ai/deploy/llamacpp-rpc

# Edit .env.rpc:
#   MAIN_PORT=31360
#   RPC_BACKENDS=<every shard host:port, comma-separated — e.g. orchestrator×2, hub, gaming-c, gaming-a, gaming-b if applicable>
#   MODELS_DIR=/mnt/cluster/llama-cpp/models   # NFS mount from hub
#   MODEL_FILE=Qwen3-Coder-Next-Q4_K_M/Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf
#   MODEL_ALIAS=qwen3-coder-next-80b-a3b
#   CTX_SIZE=32768
#   N_GPU_LAYERS=999
#   CHAT_TEMPLATE=chatml
#   PARALLEL=1
#   LLAMA_API_KEY=change-me        # must match litellm_config.yaml

docker compose --env-file .env.rpc -f docker-compose.rpc-main.yml up -d
```

CLI `--env-file` interpolates the Compose file only. The 27B/80B pool overlay
runs `run-llama-server-coordinator.sh`, which reads `RPC_BACKENDS` from the
**container** environment. That overlay sets service `env_file: .env.rpc`
([Compose env_file](https://docs.docker.com/reference/compose-file/services/#env_file)).

Watch the load:

```bash
docker logs -f llamacpp-rpc-main 2>&1 | grep -E 'rpc|load|model|HTTP server listening'
# Expected: one "connecting" line per entry in RPC_BACKENDS, then:
#   llama_model_load: model ...Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf...
#   HTTP server listening: 0.0.0.0:31360
```

### Step 5 — wire LiteLLM on `hub`

On the brain, `deploy/.env` already references the coordinator:

```env
LLAMACPP_RPC_URL=http://orchestrator
# And LiteLLM routes the `frontier-code` alias at it (see
# deploy/litellm_config.yaml).
```

Restart LiteLLM and smoke-test (ensure dedicated **`alfa-redis`** and **`alfa-postgres`** from protected stacks are up)
first — LiteLLM cache + Prisma require both):

```bash
ssh operator@hub
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
# Dedicated DB stacks (protected):
sudo docker compose --env-file .env -f docker-compose.redis.yml up -d
sudo docker compose --env-file .env -f docker-compose.postgres.yml up -d
sudo docker compose --env-file .env up -d --force-recreate alfa-ai-litellm
bash ../deploy/cluster-members/_common/wait-litellm-liveliness.sh 120

# Smoke test (host port from deploy/.env, default 8413)
bash -lc 'set -a; source .env; set +a; curl -fsS --max-time 600 -X POST http://127.0.0.1:8413/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"frontier-code\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"Write a TypeScript LRU cache, no deps.\"}]}"'
```

Re-benchmark latency/throughput after cutover; **80B** is heavier than **30B**.

## Routine operations

### Restart a single backend

`rpc-server` is stateless — the coordinator reconnects automatically:

```bash
docker compose --env-file .env.rpc -f docker-compose.rpc-server.yml restart
```

The in-flight request fails (clients retry via LiteLLM's built-in retry);
new requests route through the reconnected backend once the coordinator
sees it healthy (~10–20 s).

### Restart the coordinator

Heavier — the GGUF reloads and **all** RPC handshakes re-run. Expect **minutes**
of downtime on `frontier-code` for **80B**. If **Petals** is **stopped** for **3b**
mode, there is **no** parallel **3a** path until you switch modes.

```bash
docker compose --env-file .env.rpc -f docker-compose.rpc-main.yml restart
```

### Swap the tier-3b model

Model change is config-only. Stop the coordinator, point `MODEL_FILE` at
the new GGUF, optionally bump `CTX_SIZE`, restart:

```bash
# On gaming-b:
sed -i 's/^MODEL_FILE=.*/MODEL_FILE=<new>.gguf/' .env.rpc
docker compose --env-file .env.rpc -f docker-compose.rpc-main.yml \
  up -d --force-recreate
```

`rpc-server` backends do **not** need restart — they're model-agnostic.

### Tune VRAM headroom

Pinned **`b7186`** `rpc-server` does **not** expose `--mem`; backends report device VRAM automatically. If the coordinator reports "not enough memory" when loading big contexts, lower **`CTX_SIZE`** on the coordinator, reduce **`--n-gpu-layers`** / tensor split, or free VRAM on the host (check `nvidia-smi`). After a future upstream bump, re-check whether `rpc-server` gained an explicit memory cap.

## Health checks

```bash
# Coordinator HTTP (OpenAI-compatible):
curl -fsS -H "Authorization: Bearer $LLAMA_API_KEY" \
  http://orchestrator/v1/models
#   → {"data":[{"id":"qwen3-coder-next-80b-a3b", ...}]}

# Backend TCP reachability from the coordinator host (paste the same list as in .env.rpc):
# export RPC_BACKENDS='orchestrator,orchestrator,...'
for hp in $(echo "$RPC_BACKENDS" | tr ',' ' '); do
  echo -n "$hp: "; timeout 2 bash -c "</dev/tcp/${hp/:/ }" && echo OK || echo DOWN
done

# LiteLLM end-to-end (frontier-code route):
curl -sS http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"frontier-code","messages":[{"role":"user","content":"ping"}],"max_tokens":4}'
```

The cluster hosts panel at `/alfa-ai/admin/health` on `hub` will show
`gaming-b` coordinator + rpc-server shards once the operator-UI entries are
added (see `build_cluster_hosts_report()` in
[`src/api/worker_monitoring.py`](../src/api/worker_monitoring.py)).

**Admin UI probe protocol (mandatory):** the coordinator (`llama-server`,
real HTTP) is checked with an HTTP `GET /health`. `rpc-server` **shard**
ports (e.g. `inference:31356`/`:31357`) are checked with a plain **TCP-connect**
probe (`_tcp_check()` in `worker_monitoring.py`) — never HTTP. Sending an
HTTP request to a shard port leaves the connection open until the client
timeout and matches the "Accepted client connection" / "Client connection
closed" churn visible in `docker logs` on the shard when this rule is
violated (root cause fixed 2026-07-05; see "Do not curl rpc-server ports"
above).

## 6 GB GPUs (deferred — last integration step)

**Inventory:** **`apps`** (GTX 1660 Super **6 GB**) and **`secondary`** (RTX **3050 6 GB**)
per [NODE_INVENTORY.md](NODE_INVENTORY.md). **Do not** add them to **`RPC_BACKENDS`**
until you have validated memory and stability.

**Official / upstream references (read before enabling):**

| Topic | Reference |
|-------|-----------|
| **GGUF size / quant choice** | [Qwen/Qwen3-Coder-Next-GGUF](https://huggingface.co/Qwen/Qwen3-Coder-Next-GGUF) — pick a quant that fits the **aggregate** shard budget after weights + KV. |
| **`llama-server` memory controls** | [examples/server/README.md](https://github.com/ggml-org/llama.cpp/blob/master/examples/server/README.md) — **`--tensor-split` / `-ts`**, **`--n-gpu-layers` / `-ngl`**, **`--main-gpu` / `-mg`**, context / batch flags. |
| **Automatic VRAM fitting** | [Discussion #18049](https://github.com/ggml-org/llama.cpp/discussions/18049) — **`--fit`** / **`--fit-target`** / **`--fit-ctx`** (when you do **not** pin `-ngl` / `-ts` yourself). |
| **Large RPC tensor loads (`-dio`)** | [Issue #19745](https://github.com/ggml-org/llama.cpp/issues/19745) — **`llama-server` / `llama-cli`** may need **`-dio`** (direct I/O) so very large models load over RPC without mmap-related hangs; test your build + GPU generation. |

**Operational options** if a **6 GB** card still cannot safely hold its shard:
omit it from the pool (fewer but larger shards), reduce **`CTX_SIZE`**, use a **smaller** GGUF quant from the Qwen repo, or wait for a **newer** pinned `llama.cpp` tag after upstream fixes.

## Known upstream issues (watch when bumping `llama.cpp`)

The image is pinned to a known-good **`b-tag`** (see `Dockerfile.rpc-cuda128`).
When upgrading, re-vet against MoE + RPC bugs, including:

- [ggml-org/llama.cpp#17938](https://github.com/ggml-org/llama.cpp/issues/17938)
  — RPC memory-accounting regression for MoE experts.
- [ggml-org/llama.cpp#18882](https://github.com/ggml-org/llama.cpp/issues/18882)
  — gibberish outputs on multi-node RPC MoE pipelines.
- [ggml-org/llama.cpp#19745](https://github.com/ggml-org/llama.cpp/issues/19745)
  — large-model load / mmap behavior; **`-dio`** mitigation documented in the thread.
- [ggml-org/llama.cpp#20587](https://github.com/ggml-org/llama.cpp/issues/20587)
  — 80B-A3B class on **Blackwell** — confirm fix level for your `sm_120` stack.

Plan and cutover criteria: [QWEN3_MIGRATION.md § Phase 5](QWEN3_MIGRATION.md#phase-5--gpu-frontier-code-qwen3-coder-next-80b-a3b-active-plan).

## Native tool calling smoke (GATE-TC)

OpenCode and alfa-ai agent Phase 3 require **native OpenAI `tools` / `tool_calls`**
end-to-end (client -> LiteLLM `:8413` -> coordinator `:31360`). Chat-only smokes
(`scripts/smoke-grev27-litellm-chat.sh`) do **not** prove this path.

**Prerequisite:** inference up, LiteLLM liveliness OK, bearer key in env.

**From `orchestrator` (PowerShell as `operator`) or any LAN host with Python 3:**

```powershell
$env:LITELLM_API_KEY = "change-me"
python scripts/test_native_tool_calling.py
```

Optional overrides: `--base-url http://hub`, `--model frontier-code`,
`--timeout 120`.

**Pass criteria:** script prints `case1 tool_call: PASS` and `case2 follow-up: PASS`
then `GATE-TC: PASS (both cases)` (exit 0).

**If FAIL:** see [.cursor/plans/ALFA_AI_STANDALONE_OPENCODE.md](../.cursor/plans/ALFA_AI_STANDALONE_OPENCODE.md)
GATE-TC section (llama.cpp function-calling docs, LiteLLM pass-through, fallback
harness order). Do not proceed to OpenCode Wave A1 until GATE-TC passes.

Official references:
- https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md
- https://docs.litellm.ai/docs/completion/function_call

## Known issue (tracked) — RPC `network_mode: host` on Win11 Docker Desktop

`deploy/llamacpp-rpc/docker-compose.rpc-server.dual-gpu-93.yml` (the `orchestrator` 2x
GPU compose) deliberately uses **published ports** (`ports: ["${RPC_PORT}:${RPC_PORT}"]`)
and explains in a comment that `network_mode: host` on Docker Desktop binds
inside the Linux VM only — Windows `netstat` will not see :31350/:31355,
and shards are not LAN-visible from the `gaming-b` coordinator unless WSL2
**mirrored** networking is enabled on the host.

The single-GPU `docker-compose.rpc-server.yml` (used by `gaming-c` gaming-worker-c and `gaming-a`
gaming-worker-a) and `docker-compose.rpc-main.yml` (the coordinator on `gaming-b`) still
use `network_mode: host` without the published-ports fallback. **Validate per
host:**

```powershell
# On the coordinator host, confirm each shard is reachable on the LAN:
nc -zv orchestrator  31351
nc -zv orchestrator 31352
# If any returns "connection refused", either enable WSL2 mirrored networking
# on that host (Settings -> Resources -> Network -> "Mirrored") OR mirror the
# dual-gpu-93.yml pattern (drop network_mode: host, add ports:).
```

A focused PR to propagate the `ports:` pattern is the standard fix; tracked as
a follow-up so it can be tested per host instead of bundled with the rebalance.

## Failure mode cheat-sheet

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `connect: connection refused` to a shard | `rpc-server` not up, or `RPC_PORT` mismatch | Restart the backend; confirm `.env.rpc` `RPC_PORT`. |
| Coordinator hangs on model load | NFS mount dropped on `gaming-b` | `mountpoint /mnt/cluster`; remount + restart. |
| 500 "model not loaded" via LiteLLM | `MODEL_ALIAS` mismatch with `litellm_config.yaml` | Align `MODEL_ALIAS` on `gaming-b` and LiteLLM's `frontier-code` `model` field. |
| 401 from coordinator | `LLAMA_API_KEY` mismatch | Align `.env.rpc` `LLAMA_API_KEY` with LiteLLM's `frontier-code` `api_key`. |
| GGML "out of memory" mid-decode | KV / weights exceed free VRAM on one shard | Lower `CTX_SIZE` or coordinator GPU layer split; free VRAM on that host (`nvidia-smi`). (`b7186` `rpc-server` has no `--mem` knob.) |
| Gibberish / repeated tokens | Wrong `CHAT_TEMPLATE` or corrupt GGUF | Re-pull GGUF; set `CHAT_TEMPLATE=chatml` for official Qwen3-Coder Q4_K_M. |

## Related

- [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md) — rationale + Phase 5 backlog.
- [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md) — whole-cluster topology.
- [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) — port 31350/31351/31352/31360.
- [NODE_INVENTORY.md](NODE_INVENTORY.md) — per-host role in the dual runtime.
- [SOURCE_OF_TRUTH_AND_SYNC.md](SOURCE_OF_TRUTH_AND_SYNC.md) — where the GGUF
  lives on the hub hub.
- [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) §2.2b — GGUF
  pre-staging procedure.
