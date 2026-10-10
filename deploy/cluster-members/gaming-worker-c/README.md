# gaming-worker-c (`gaming-c`) — Dockge worker + optional RPC (Petals retired)

Win11 host **`orchestrator`**: RTX 5070 12 GB (Blackwell). **Petals/Hivemind retired
2026-07-09** — do not bring up `petals-worker`. Role today: Dockge agent + optional
RPC shard. Historical CPU quality LLM / embed notes below are superseded by the
four-host pool (RAG on `inference`).

| Field | Value |
|-------|--------|
| IP | `orchestrator` |
| GPU | RTX 5070 12 GB (Blackwell) |
| CPU / RAM | i7-12700 12c/20t, **64 GB DDR4** |
| Primary path | Dockge + optional `deploy-llamacpp-rpc.ps1` |
| Hub SMB | `Y:` -> `\\hub\petals-wheels` (bots/victron only) |

SSoT: [FOUR_HOST_FRONTIER_POOL.md](../../../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md) §9.

**Before first inference opt-in:** read [inference_GAMING_HOST_JOIN.md](../../../docs/inference_GAMING_HOST_JOIN.md)
(`gaming-a` / `gaming-c` join pitfalls; HTTP image load when hub SMB denied). Scripts ship
`MAX_MIB=3072` and gaming `VRAM_GB=9`.

**Agent SSH from `orchestrator`:** one-time Admin run from this folder after `git pull` --
[AGENT_SSH_FROM_93.md](AGENT_SSH_FROM_93.md) (`CONSOLE-ONE-TIME-SSH.ps1`, `id_ed25519_93_59.pub`).
After that, orchestrator **stop and start** both SSH-deploy `:31351` when `gaming-c` is
opted into `inference-shards.active.env` (commit `eeefbed`).

**Desktop shortcut (gaming / WSL):** same **ALFa Gaming Mode** icon as `orchestrator` /
`gaming-a`. One-time on this PC after `git pull` (clone the orchestrator uses, default
`C:\Users\Colin\alfa-ai`):

```powershell
cd C:\Users\Colin\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\install-gaming-desktop-shortcut.ps1
```

Creates `%USERPROFILE%\Desktop\ALFa Gaming Mode.lnk` (WScript.Shell
[CreateShortcut](https://learn.microsoft.com/en-us/previous-versions/aew9yb99(v=vs.80))).
**Start Gaming** runs `gaming-stop-for-session.ps1 -ShutdownWsl`. **Done Gaming**
starts WSL only (`gaming-resume-pool-shard.ps1`; no local shard deploy). Rejoin
inference from `orchestrator` cluster Start. Leave the live pool from `orchestrator` first
([inference_GAMING_HOST_JOIN.md](../../../docs/inference_GAMING_HOST_JOIN.md)
Desktop shortcut; llama.cpp RPC backends are fixed at coordinator start
([RPC README](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md))).

### Deferred: Petals/Hivemind cleanup (host offline as of 2026-07-09)

When this host is next online, **before** any Dockge/RPC deploy:

1. `git pull --ff-only origin main` in the host clone.
2. `wsl -d Ubuntu bash -lc 'cd /mnt/c/Users/<user>/alfa-ai && bash scripts/purge-petals-runtime-on-host.sh --apply'` (adjust path).
3. Remove Dockge stack entries named `petals-worker`.
4. Do **not** run Petals worker bring-up, `deploy-petals-gateway`, or retired `docs/petals/*`.
5. Optional: remove Windows firewall rules for DHT **31330/31331**; keep llama.cpp RPC ports per [PORT_ASSIGNMENTS.md](../../../docs/PORT_ASSIGNMENTS.md).
6. Then continue with Dockge + optional llamacpp-rpc only.

---

## CPU model plan (accuracy-first — research May 2026)

> **2026-06-17 update (supersedes the May 2026 model choices below):** `gaming-c`
> now runs **`qwen3.5:27b`** dense (quality default) + **`qwen3-embedding:4b`**,
> and `orchestrator` re-joins as the **speed** chat host (`qwen3.6:35b-a3b` MoE). All
> sub-frontier aliases no longer route to `gaming-c` *only* — see
> [ROADMAP.md § "Operator-selected models (2026-06-17)"](../../../docs/ROADMAP.md#operator-selected-models-2026-06-17--confirmed).
> Requires **Ollama 0.30.x** (Gated-DeltaNet) — verify the tag loads before
> retiring `qwen3:32b`. The May 2026 narrative is kept below for history.

**Status:** Planned — **not** wired in `litellm_config.yaml` yet. GPU roles below are
unchanged. Validate with smoke tests before cutover.

### Final plan (May 2026): `gaming-c` = sole CPU chat; `hub`/`orchestrator` = no chat LLM

The 30B MoE fleet is **retired cluster-wide**. `gaming-c` is the **only** CPU chat host.

| Finding | Detail |
|---------|--------|
| **`gaming-c` is the sole dense-32B host** | Only fleet box with **64 GB RAM** and no brain-stack / 32 GB ceiling. `hub` (~46 GiB) and `orchestrator` (32 GB) cannot host dense 32B. |
| **Accuracy gain vs MoE** | Qwen3 **32B dense** beats **30B-A3B MoE** on Qwen-published proxies: Creative Writing v3 (**78.3 vs 68.1**), LiveCodeBench v5 non-thinking (**31.3 vs 29.8**); IFEval ~tie. See [MODEL_FIT_AUDIT.md](../../../docs/MODEL_FIT_AUDIT.md). |
| **Tradeoff** | Dense 32B on CPU is **~3–6× slower** than MoE (~**2–5 tok/s** est. on i7-12700 vs ~6–18 tok/s MoE fleet). Acceptable when accuracy > speed. |
| **`hub` — no chat LLM** | Brain/LiteLLM/API only. ~46 GiB RAM needed for brain stack + ZFS; no room for 32B and no value keeping disliked 30B MoE. |
| **`orchestrator` — no chat LLM** | Gateway + 2× Petals + RPC only. 32 GB RAM fully claimed by GPU workloads. |
| **`gaming-b` — reranker only** | `Qwen3-Reranker-0.6B` + embed cold-standby. Not a chat LLM host. |
| **Fallback when `gaming-c` down** | Route to **`frontier`** (70B Petals GPU) — not back to MoE. |

### Target model on `gaming-c`

| Item | Value |
|------|--------|
| **Model** | **`qwen3:32b`** (Qwen3-32B-Instruct dense, text-only — not an image model) |
| **Quant (target)** | **`Q5_K_M`** (~23 GB weights) — best accuracy/RAM balance on 64 GB |
| **Quant (smoke first)** | Official Ollama tag ships **`Q4_K_M`** (~20 GB) — pull and benchmark before custom Q5 Modelfile |
| **RAM budget** | ~23 GB weights + 4–10 GB KV + OS/Docker/embed hot-swap → **~45 GB peak** (fits 64 GB) |
| **Ollama mode** | **CPU-only** — `CUDA_VISIBLE_DEVICES=` + `OLLAMA_NUM_GPU=0` (GPUs reserved for Petals / RPC) |
| **Launcher** | [ollama-service.cmd.example](./ollama-service.cmd.example) |

```powershell
# Smoke (after pull-models role exists — see hub scripts):
set CUDA_VISIBLE_DEVICES=
set OLLAMA_NUM_GPU=0
ollama pull qwen3:32b
ollama run qwen3:32b
```

### Planned LiteLLM routing (all sub-frontier → `gaming-c`)

| Alias group | Backend |
|-------------|---------|
| `fast`, `inline`, `autocomplete`, `chat`, `agent`, `code`, `public-chat`, `app-chat` | **`qwen3:32b` on `gaming-c` only** |
| Hard coding | **`frontier-code`** (80B GPU RPC) — not CPU |
| Strict instruction / email tone | **`frontier`** (70B Llama Petals) when quality ceiling matters |
| Fallback (`gaming-c` down) | **`frontier`** (70B Petals) — no MoE fallback |

**Caveat:** Dense **32B Instruct** may differ from Coder MoE on repo/agent coding —
route hard coding to **`frontier-code`** (80B) for best results.

### Coexistence with embed + GPU on `gaming-c`

- **`nomic-embed-text`** stays primary on `:11434` (`OLLAMA_MAX_LOADED_MODELS=1` — Ollama
  swaps between embed and 32B; avoid parallel heavy RAG + long 32B generations during smoke).
- **Petals worker** and **llama.cpp `rpc-server`** (tier 3b) on RTX 5070 are **unchanged**.

### Operator checklist (before cutover)

1. Pull `qwen3:32b` on `gaming-c`; measure peak RSS and tok/s with CPU-only env.
2. Confirm Q5 Modelfile path if Q4 accuracy is insufficient ([HF GGUF](https://huggingface.co/unsloth/Qwen3-32B-GGUF) + Ollama Modelfile).
3. Update `litellm_config.yaml` — collapse all aliases to `gaming-c` only (Phase 3 on `hub`).
4. Stop Ollama on `hub` and `orchestrator` after LiteLLM cutover confirmed.

Related: [NODE_INVENTORY.md](../../../docs/NODE_INVENTORY.md) § CPU fleet,
[QWEN3_MIGRATION.md](../../../docs/QWEN3_MIGRATION.md), [gaming-worker-b-249 CPU reranker](../gaming-worker-b-249/README.md#cpu-reranker-plan-research-may-2026).

---

## Before you start (once per cluster, on `orchestrator`)

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stage-cluster-members.ps1
```

---

## One-time on gaming-worker-c (lessons from gaming-worker-a `gaming-a`)

### 1. hub SMB user on `hub` (operator)

`operator` is SSH-only on hub. Each Windows worker needs its **own local SMB user** with ACL on hub shares (`petals-wheels`, `huggingface`, `docker-images`). See [HUB_ARTIFACTS.md](../../../docs/HUB_ARTIFACTS.md).

On `hub` shell (example username `gaming-worker-c` — pick one and use consistently):

```bash
setopt interactivecomments
sudo midclt call user.create '{"username":"gaming-worker-c","full_name":"gaming-worker-c (gaming-c)","group_create":true,"password": "change-me","smb":true}'
```

Then **Storage → Datasets → ACL**: grant that user **Read** on `HDDs/Alfa-AI/wheels`, `models/huggingface`, `docker-images`.

Verify:

```bash
sudo smbclient //127.0.0.1/petals-wheels -U 'gaming-worker-c%PASSWORD' -c 'ls cuda-blackwell; exit'
```

### 2. Prerequisites on `gaming-c`

**Docker:** WSL Docker Engine in Ubuntu — **not** Docker Desktop. Follow
[WINDOWS_WSL_ROLLOUT_CHECKLIST.md](../../../docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md)
Phases A–B before deploy.

| Item | gaming-worker-c (`gaming-c`) |
|------|-----------------|
| Firewall TCP | **`31330`, `31331`, `31351`, `11434`** (DHT, monitor, RPC tier 3b, Ollama embed) |
| Post-startup | `-HostProfile gaming-worker-c-59 -WarmUpSec 180` → **`RESULT: OK`** |
| Remote verify | From `apps`: DHT `:31330`, optional Ollama `:11434` |

Admin firewall:

```powershell
. C:\Users\YOURUSER\alfa-ai\deploy\cluster-members\_common\open-petals-firewall.ps1
Open-AlfaPetalsWorkerFirewall -DisplayNamePrefix 'ALFa gaming-worker-c-59' -TcpPorts 31330,31331,31351,11434 -Profile Any
```

Also required:

- `wsl -d Ubuntu nvidia-smi` and `wsl -d Ubuntu docker ps` succeed.
- `apps` UFW allows `31330/tcp` from `orchestrator`.
- **`apps` bootstrap** `petals-worker` must be **Up** before join.
- Windows clock within **3 seconds** of cluster. **Admin** `w32tm /resync /force` if Petals reports time skew.

### 3. Git checkout

```powershell
git clone https://github.com/example/alfa-ai.git C:\Users\YOURUSER\alfa-ai
cd C:\Users\YOURUSER\alfa-ai
git pull --ff-only origin main
```

### 4. Prep (normal user — not Admin)

Copy from **Notepad** (chat apps strip `\\` in UNC paths):

```powershell
cd C:\Users\YOURUSER\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\_common\prep-windows-blackwell-worker.ps1 `
  -MemberFolder gaming-worker-c-59 -SmbUser gaming-worker-c
```

This maps **`Y:`/`Z:`** via `hub`, copies `.env.worker`, strips CRLF, and probes bootstrap auth.

### 5. Secrets — edit both files (same token)

```powershell
notepad C:\Users\YOURUSER\alfa-ai\deploy\cluster-members\gaming-worker-c\.env.worker
notepad C:\Users\YOURUSER\alfa-ai\deploy\petals\.env.worker
```

| Key | Value |
|-----|--------|
| `ALFA_WORKER_HEARTBEAT_TOKEN` | **Exact** `ALFA_WORKER_HEARTBEAT_TOKEN` from `hub` `deploy/.env` (64 chars — **not** the short `ALFA_AI_API_TOKEN`) |
| `HF_TOKEN` | Hugging Face token (gated Llama-3.3) |
| `ALFA_BRAIN_URL` | `http://hub` |
| `PETALS_INITIAL_PEERS` | Leave **empty** |

Re-run prep after editing token if bootstrap probe was 403.

Optional **Admin once**: add `hub hub` to `C:\Windows\System32\drivers\etc\hosts` so `\\hub\...` scripts work.

---

## Deploy

**Normal user** (build-start opens firewall; may prompt Admin):

```powershell
cd C:\Users\YOURUSER\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\gaming-worker-c\build-start-gaming-worker-c-59.ps1
```

First run builds `alfa-petals-ml-base:cuda-blackwell` from **`Y:`** wheels (**10–30 min**).

Optional: `-SkipPrep` if prep already done; `-SkipLogUpload` without SSH to `inference` hub.

---

## Logs (automatic)

Transcript: `deploy\cluster-members\gaming-worker-c\logs\build-start-<UTC>.log`  
Upload: `operator@orchestrator:/home/operator/alfa-ai/logs/cluster-docker/`  
See [gaming-worker-a-219/README.md](../gaming-worker-a-219/README.md) § Logs.

---

## Verify (gate before CPU tier / LiteLLM cutover)

**Post-startup gate (required):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\_common\run-post-startup-status-with-log.ps1 `
  -HostProfile gaming-worker-c-59 -WarmUpSec 180
```

**Worker smoke:**

```powershell
wsl -d Ubuntu docker logs petals-worker --tail 30
Invoke-RestMethod http://127.0.0.1:31331/health | ConvertTo-Json -Compress
Invoke-RestMethod http://orchestrator/health | ConvertTo-Json -Compress
```

Pass when logs show **`initial peers: ['/ip4/apps/tcp/31330/p2p/...']`** and **`Announced that blocks [...] are joining`**.

Register on `hub` admin (JWT from browser):

```bash
curl -sS -X POST http://hub/alfa-ai/api/admin/workers \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"gaming-worker-c","ip_address":"orchestrator","monitor_port":31331,"role":"gpu-worker"}'
```

---

## Next host

When gaming-worker-c passes Petals + post-startup, wire CPU tier (`qwen3:32b` + embed) per § CPU model plan above. **`gaming-b` gaming-worker-b** deploys after gaming-worker-c if following June 2026 order — see [../gaming-worker-b-249/README.md](../gaming-worker-b-249/README.md).
