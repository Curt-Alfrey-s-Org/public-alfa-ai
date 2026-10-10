# gaming-worker-b (`gaming-b`) — Dockge worker + optional llama.cpp RPC (Petals retired)

Win11 host **`orchestrator`**: RTX 5070 12 GB (Blackwell). **Petals/Hivemind retired
2026-07-09** — do not bring up `petals-worker`. Role today: Dockge agent + optional
RPC shard when the operator wants capacity. Also **embed cold-standby** / planned
CPU reranker (separate from inference).

| Field | Value |
|-------|--------|
| IP | `orchestrator` |
| GPU | RTX 5070 12 GB (Blackwell) |
| CPU / RAM | i7-11700 8c/16t, **64 GB DDR4** |
| Primary path | Dockge + optional `deploy-llamacpp-rpc.ps1` |
| Hub SMB | `Y:` -> `\\hub\petals-wheels` (bots/victron only; not Petals ml-base) |

SSoT: [FOUR_HOST_FRONTIER_POOL.md](../../../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md) §9.

**Before first inference opt-in:** read [inference_GAMING_HOST_JOIN.md](../../../docs/inference_GAMING_HOST_JOIN.md)
(gaming-host pitfalls; HTTP image load when hub SMB denied). Scripts ship
`MAX_MIB=3072` and gaming `VRAM_GB=9`.

**Agent SSH from `orchestrator`:** one-time Admin run after `git pull` --
[AGENT_SSH_FROM_93.md](AGENT_SSH_FROM_93.md) (`CONSOLE-ONE-TIME-SSH.ps1`,
`id_ed25519_93_249.pub`). After that, orchestrator **stop and start** both
SSH-deploy `:31358` when `gaming-b` is opted into `inference-shards.active.env`.

**Desktop shortcut (gaming / WSL):** same **ALFa Gaming Mode** icon as `orchestrator` /
`gaming-a`. One-time on this PC after `git pull` (clone the orchestrator uses, default
`C:\Users\cody\alfa-ai`; if this host uses `C:\alfa-ai-worker`, `cd` there):

```powershell
cd C:\Users\cody\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-b\install-gaming-desktop-shortcut.ps1
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

## CPU reranker plan (research May 2026)

**Status:** Planned — reranker is **not** a chat LLM and has **no** LiteLLM alias yet.
GPU coordinator / Petals roles below are unchanged.

### Why `gaming-b` for reranker (not dense 32B)

| Host | RAM | CPU | Best CPU role |
|------|-----|-----|----------------|
| **`gaming-c`** | 64 GB | i7-12700 **12c/20t** | **Dense `qwen3:32b`** quality LLM + primary embed |
| **`gaming-b`** | 64 GB | i7-11700 **8c/16t** (slower) | **Reranker** + embed cold-standby — ample RAM, wrong box for slow 32B inference |
| **`hub`** | ~46 GiB | 7900X (fast) | Brain + MoE speed/fallback — no headroom for dense 32B Q5+ |
| **`orchestrator`** | 32 GB | 7900X (fast) | MoE speed tier only |

Research verdict: **`gaming-b` should not run duplicate `qwen3-coder:30b-a3b` MoE** once the
split tier is live. Freeing that ~18 GB and CPU time for a tiny reranker is higher
value than a fourth slow MoE copy.

### Target reranker

| Item | Value |
|------|--------|
| **Model** | **`Qwen3-Reranker-0.6B`** (Qwen family; llama.cpp sidecar) |
| **GGUF on hub** | `Qwen3-Reranker-0.6B.Q4_K_M.gguf` at `/mnt/HDDs/Alfa-AI/models/downloads/reranker/` (NFS: `/mnt/cluster/models/downloads/reranker/`) |
| **Seed** | On `hub`: `sudo bash scripts/seed-qwen3-reranker-gguf-hub.sh` |
| **Size** | ~**418 MB** Q4_K_M |
| **Why this model** | Already listed in [ROADMAP.md](../../../docs/ROADMAP.md) and [NODE_INVENTORY.md](../../../docs/NODE_INVENTORY.md); strong quality/latency tradeoff for RAG |
| **Alternatives** | `Qwen3-Reranker-4B` / `8B` if accuracy needs grow (hub seed only on `hub`) |

### Integration note

Ollama has **no native rerank API**. Expect one of:

- **llama.cpp sidecar** + GGUF Modelfile (community pattern), or
- App-level cross-encoder in the brain/RAG pipeline

Wire-up is a **follow-on** after `gaming-c` `qwen3:32b` smoke tests. Reranker improves
**retrieval accuracy** (ranking chunks before the LLM), not raw generation quality.

Runbook detail: [ollama-embed-standby.md](./ollama-embed-standby.md) (embed failover unchanged).

Related: [gaming-worker-c-59 CPU quality plan](../gaming-worker-c-59/README.md#cpu-model-plan-accuracy-first--research-may-2026).

---

## Before you start (once per cluster, on `orchestrator`)

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stage-cluster-members.ps1
```

---

## One-time on gaming-worker-b (lessons from gaming-worker-a `gaming-a`)

### 1. hub SMB user on `hub` (operator)

`operator` is SSH-only on hub. Each Windows worker needs its **own local SMB user** with ACL on hub shares (`petals-wheels`, `huggingface`, `docker-images`). See [HUB_ARTIFACTS.md](../../../docs/HUB_ARTIFACTS.md).

On `hub` shell (example username `gaming-worker-b` — pick one and use consistently):

```bash
setopt interactivecomments
sudo midclt call user.create '{"username":"gaming-worker-b","full_name":"gaming-worker-b (gaming-b)","group_create":true,"password": "change-me","smb":true}'
```

Then **Storage → Datasets → ACL**: grant that user **Read** on `HDDs/Alfa-AI/wheels`, `models/huggingface`, `docker-images`.

Verify:

```bash
sudo smbclient //127.0.0.1/petals-wheels -U 'gaming-worker-b%PASSWORD' -c 'ls cuda-blackwell; exit'
```

### 2. Prerequisites on `gaming-b`

**Docker:** WSL Docker Engine in Ubuntu — **not** Docker Desktop. Follow
[WINDOWS_WSL_ROLLOUT_CHECKLIST.md](../../../docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md)
Phases A–B before deploy.

Phase A (repo owner, normal PowerShell):

```powershell
cd C:\Users\Cody\alfa-ai
git pull --ff-only origin main
copy deploy\cluster-members\_common\wslconfig-petals.example $env:USERPROFILE\.wslconfig -Force
wsl --shutdown
```

Path uses **`cluster-members\_common\`** (backslash before `_common`). Win11 gaming-worker-b
uses the mirrored template; Win10 hosts use `wslconfig-petals-win10-nat.example`.

| Item | gaming-worker-b (`gaming-b`) |
|------|----------------|
| Firewall TCP | **`31330`, `31331`, `31360`** (DHT, monitor, RPC coordinator) |
| Post-startup | `-HostProfile gaming-worker-b-249 -WarmUpSec 180` → **`RESULT: OK`** |
| Remote verify | From `apps`: DHT `:31330` |

Admin firewall:

```powershell
. C:\Users\YOURUSER\alfa-ai\deploy\cluster-members\_common\open-petals-firewall.ps1
Open-AlfaPetalsWorkerFirewall -DisplayNamePrefix 'ALFa gaming-worker-b-249' -TcpPorts 31330,31331,31360 -Profile Any
```

Also required:

- `wsl -d Ubuntu nvidia-smi` and `wsl -d Ubuntu docker ps` succeed.
- `apps` UFW allows `31330/tcp` from `orchestrator` (already present).
- **`apps` bootstrap** `petals-worker` must be **Up** before join.
- Windows clock within **3 seconds** of cluster — see § Clock sync below.

### 2a. Clock sync (lesson from gaming-worker-c `gaming-c`)

Petals/hivemind DHT rejects a peer whose local time is **>3 s** off. On `gaming-c` the
**W32Time service was stopped**, so `w32tm /resync` failed with `0x80070426`.
Run this once in **Admin PowerShell** (not just `w32tm /resync`):

```powershell
Set-Service W32Time -StartupType Automatic
Start-Service W32Time
w32tm /config /manualpeerlist:"time.windows.com,0x9 pool.ntp.org,0x9" /syncfromflags:manual /reliable:YES /update
Restart-Service W32Time
w32tm /resync /force
w32tm /query /status
```

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
  -MemberFolder gaming-worker-b-249 -SmbUser gaming-worker-b
```

### 5. Secrets — edit both files (same token)

```powershell
notepad C:\Users\YOURUSER\alfa-ai\deploy\cluster-members\gaming-worker-b\.env.worker
notepad C:\Users\YOURUSER\alfa-ai\deploy\petals\.env.worker
```

| Key | Value |
|-----|--------|
| `ALFA_WORKER_HEARTBEAT_TOKEN` | **Exact** `ALFA_WORKER_HEARTBEAT_TOKEN` from `hub` `deploy/.env` (64 chars) |
| `HF_TOKEN` | Hugging Face token |
| `ALFA_BRAIN_URL` | `http://hub` |
| `PETALS_INITIAL_PEERS` | Leave **empty** |

Re-run prep after editing token if bootstrap probe was 403.

Optional **Admin once**: `hub hub` in hosts file.

### Windows cache root (avoid filling C:)

Large docker tarballs and hub promotes use `*\alfa-ai-cache\docker-images\`, not
hardcoded `C:\` when another fixed NTFS drive is under **80%** full.

At deploy/prep start, gaming-worker-b scripts call
`_common\Get-AlfaWindowsCacheRoot.ps1` via `Initialize-Alfa249CacheRoot.ps1`:

| Priority | Rule |
|----------|------|
| 1 | Env `ALFA_WINDOWS_CACHE_ROOT` if set (e.g. `G:\alfa-ai-cache`) |
| 2 | Prefer **G:** when eligible |
| 3 | Else non-**C:** drive with most free space (>= 30 GB free, < 80% used) |
| 4 | **C:** only when no other eligible fixed NTFS drive exists |

WSL `docker load` uses `/mnt/<letter>/alfa-ai-cache/docker-images/...` matching
the picked Windows path. inference offline prep on `gaming-b`:
`Prep-gaming-worker-b249inferenceReady.ps1` (Initialize env pin, then shared
`_common\Prep-GamingHostinferenceReady.ps1`).

**Open (2026-10-05):** `gaming-b`'s SSD failed and also blocked boot on `orchestrator` while
attached. **Do not put that disk back in as a boot disk** on `gaming-b` or `orchestrator`.
The recovered inference image cache is on `orchestrator` at `E:\alfa-ai-cache\docker-images\`
(`alfa-llamacpp-rpc-cuda128-b10355.tar.gz` and `images.json`). `E:\Games` on
`orchestrator` stays untouched. After `gaming-b` boots, copy those two files into
`<non-C>:\alfa-ai-cache\docker-images\` on `gaming-b`. Set the **User** environment
variable `ALFA_WINDOWS_CACHE_ROOT` to `<non-C>:\alfa-ai-cache` (the path must
end in `\alfa-ai-cache`, not `\docker-images`). This is the inference image cache,
not the `.45b` trainer.

Official: [Get-CimInstance](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance)
(`Win32_LogicalDisk`), [Win32_LogicalDisk](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-logicaldisk).

---

## Deploy

**Normal user** — `build-start-gaming-worker-b-249.ps1` opens firewall (host + Hyper-V) via
`_common\open-petals-firewall.ps1` with ports **`31330`, `31331`, `31360`**.

```powershell
cd C:\Users\YOURUSER\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\gaming-worker-b\build-start-gaming-worker-b-249.ps1
```

First run builds `alfa-petals-ml-base:cuda-blackwell` from **`Y:`** wheels (**10–30 min**).

Optional: `-SkipPrep`, `-SkipLogUpload`.

### `-ForceBuild` — stale hub tarball (lesson from gaming-worker-c `gaming-c`)

The hub `docker-images` tarball for `alfa-petals-worker-gpu:12.8.0-cuda-blackwell`
can be an **old image** whose entrypoint references `/usr/local/bin/worker-heartbeat.sh`
but doesn't ship it. If the worker crash-loops on a missing `worker-heartbeat.sh`,
re-run with **`-ForceBuild`** to skip the tarball load and rebuild from the git checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\gaming-worker-b\build-start-gaming-worker-b-249.ps1 -ForceBuild
```

---

## Logs (automatic)

Transcript: `deploy\cluster-members\gaming-worker-b\logs\build-start-<UTC>.log`  
Upload: `operator@orchestrator:/home/operator/alfa-ai/logs/cluster-docker/`  
See [gaming-worker-a-219/README.md](../gaming-worker-a-219/README.md) § Logs.

---

## Verify (full-cluster gate)

**Post-startup gate (required):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\_common\run-post-startup-status-with-log.ps1 `
  -HostProfile gaming-worker-b-249 -WarmUpSec 180
```

```powershell
wsl -d Ubuntu docker logs worker-monitor --tail 30
curl.exe -fsS --max-time 10 http://127.0.0.1:31331/health
curl.exe -fsS --max-time 10 http://hub/health/liveliness
```

Register on `hub` admin:

```bash
curl -sS -X POST http://hub/alfa-ai/api/admin/workers \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"gaming-worker-b","ip_address":"orchestrator","monitor_port":31331,"role":"gpu-worker"}'
```

---

## After all three hosts

- Confirm inference opt-in shard is up (RPC **`:31358`** on `gaming-b`) — **not** Petals **`.157:31330`** (retired).
- Re-run frontier smoke from `apps` (LiteLLM `model=frontier`).
- See WORKER_ROLLOUT § Phase 3 gate 7.
