# `orchestrator` (operator-93) — operator commands

Win11 host **orchestrator**: primary **Dockge** (`:5002`), **Petals gateway** (`:8413`), dual-GPU **Petals workers**. Brain API/LiteLLM live on **`hub`** (`hub` LiteLLM — same port number, different host). Apps DB/cache on **`apps`**.

**Fleet readiness checklist (Ampere / `cuda` variant):** [docs/FLEET_HOST_READINESS.md](../../../docs/FLEET_HOST_READINESS.md) § `orchestrator`.

Full narrative: [docs/petals/WORKER_ROLLOUT.md](../../../docs/petals/WORKER_ROLLOUT.md) § Phase 2.

---

## CPU chat — speed host (2026-06-17)

`orchestrator` re-joins as a **CPU chat host** (it ran no chat LLM under the May 2026 plan):
the **speed** tier serving **`qwen3.6:35b-a3b`** MoE (~22 GB Q4_K_M, ~3B active)
CPU-only on the 7900X + DDR5-6400 (~18–30 tok/s). LiteLLM routes the
`fast`/`inline`/`autocomplete` aliases here (quality aliases stay on `gaming-c`
`qwen3.5:27b`; each is the other's fallback). See
[ROADMAP.md § "Operator-selected models (2026-06-17)"](../../../docs/ROADMAP.md#operator-selected-models-2026-06-17--confirmed).

- **Prereq:** Ollama **0.30.x** (Gated-DeltaNet arch) — verify the tag loads first.
- **CPU-only** (GPUs are committed to Petals/RPC): `CUDA_VISIBLE_DEVICES=` + `OLLAMA_NUM_GPU=0`.
- **RAM:** ~22 GB resident + KV in 32 GB is tight — cap `OLLAMA_CONTEXT_LENGTH` (e.g. 32768),
  quantize KV, and don't co-locate other heavy RAM users.
- Pull: `pull-models.ps1 -Role Speed` (tag `qwen3.6:35b-a3b`).

---

## Hub-first Docker tarballs (May 2026)

`deploy.ps1` (step 2) and `deploy-petals-gateway.ps1` use **`deploy/cluster-members/_common/load-hub-tarball.ps1`**:

1. Copy the tarball from **`\\hub\docker-images\<file>`** to **`<cache-root>\docker-images\`** (`Get-AlfaWindowsCacheRoot` on `orchestrator`; override **`ALFA_WINDOWS_CACHE_ROOT`**).
2. Skip the copy when the **local file size matches the hub file size**.
3. `docker load -i <local>` — never streams a 5-15 GB tarball through WSL2 over SMB.

**Same tarball across Windows hosts** is fine when the **GPU variant matches**:

| Tarball | Works on |
|---|---|
| `alfa-ai-petals-gateway-local.tar.gz` | any Windows host |
| `alfa-petals-worker-gpu-12.4.1-cuda-runtime.tar.gz` | Ampere / Ada (RTX 30xx / 40xx) — e.g. `orchestrator` |
| `alfa-petals-worker-gpu-12.8.0-cuda-blackwell.tar.gz` | Blackwell (RTX 50xx, sm_120) — `gaming-b` / `gaming-c` / `gaming-a` |

**Publishing tarballs** to the hub so other hosts can `docker load`:

```bash
# Linux host that built the image (NFS hub at /mnt/cluster/docker-images):
bash scripts/publish-built-image-to-hub.sh alfa-petals-ml-base:cuda
bash scripts/publish-built-image-to-hub.sh alfa-ai-petals-gateway:local
```

```powershell
# Windows host that built the image (SMB hub at \\hub\docker-images):
.\scripts\Publish-BuiltImage-ToHub.ps1 -ImageTag 'alfa-petals-worker-gpu:12.4.1-cuda-runtime'
```

Batch export from `apps`: **`bash scripts/export_docker_images.sh`**. Inventory + paths: [docs/HUB_ARTIFACTS.md](../../../docs/HUB_ARTIFACTS.md).

To force a re-copy from the hub: delete the matching file under `<cache-root>\docker-images\` (see `Get-AlfaWindowsCacheRoot`).

**Disk space (`orchestrator`):** in **Administrator PowerShell**:

```powershell
cd C:\Users\YOURUSER\alfa-ai\deploy\cluster-members\orchestrator
powershell -NoProfile -ExecutionPolicy Bypass -File .\compact-docker-wsl-and-move-cache-to-D.ps1
```

(`-SkipCompact` / `-SkipMoveCache` if you only want one phase.) **Docker images/cache on `C:`:** move Docker Desktop **disk image location** to `D:\` — see [docs/WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md](../../docs/WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md) §3.

**One-command build/start on `orchestrator` (GPU Petals workers + CPU Petals gateway + Dockge)** — same as `deploy.ps1`:

```powershell
cd C:\Users\YOURUSER\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\build-start-alfa-ai-93.ps1
```

Use `-SkipPull` if you already synced git. Requires **`deploy/petals/.env.worker`** (workers) and **`deploy/.env.gateway`** (gateway).

**Clean restart (teardown + delete tarball cache + redeploy)** — use when a partial deploy or stale hub cache caused trouble:

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\reset-and-redeploy.ps1
```

Stops workers/gateway/Dockge, deletes hub tarball cache under `Get-AlfaWindowsCacheRoot\docker-images\` (`.loaded` sentinels too), then runs `build-start-alfa-ai-93.ps1`. Does not wipe HF volumes or Dockge data. Does not stop IDE listeners on `:8013`. `-TeardownOnly` stops at step 2.

**Port matrix:** [docs/PORT_ASSIGNMENTS.md](../../../docs/PORT_ASSIGNMENTS.md) — primary gateway **`:8413`** on `orchestrator` (not `:8013`; IDE may use 8013 locally).

---


## 0. One-time host prep (Administrator PowerShell)

Map LAN hubs (wheels + HF cache). Docker Desktop -> Settings -> Resources -> File Sharing must allow **`Y:`** and **`Z:`**.

```powershell
net use Y: \\hub\petals-wheels /PERSISTENT:YES
net use Z: \\hub\huggingface   /PERSISTENT:YES
Test-Path Y:\cuda
Test-Path Z:\hub
```

Recommended Defender exclusions (silent quarantine on `.ps1` updates):

```powershell
Add-MpPreference -ExclusionPath 'C:/Users/operator\alfa-ai'
Add-MpPreference -ExclusionProcess 'docker.exe','dockerd.exe','git.exe'
```

Adjust `ExclusionPath` if your repo lives elsewhere.

---

## 1. Sync repo (after push from `apps`)

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
```

(`deploy.ps1` runs `git pull` again; pulling first avoids surprises.)

---

## 2. Port preflight (mandatory before first deploy and after IDE use)

Authoritative map: [docs/PORT_ASSIGNMENTS.md](../../../docs/PORT_ASSIGNMENTS.md) (*Windows `orchestrator`* section). Primary gateway listens on **`:8413`**, not `:8013`.

If `deploy\.env.gateway` still has `ALFA_AI_PETALS_GATEWAY_HOST_PORT=8013`, change it to **`8413`** before deploy.

```powershell
cd C:/Users/operator\alfa-ai
. .\deploy\cluster-members\_common\Test-AlfaWindowsDeployPortPreflight.ps1
Test-AlfaWindowsDeployPortPreflight -Profile operator-93
```

Exit code `0` required. `deploy.ps1` / `build-start-alfa-ai-93.ps1` run the same check automatically.

**Dual-GPU firewall (Administrator PowerShell as `operator`, once per host):**

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\_common\install-wsl-lan-firewall.ps1 -Profile operator-93
```

Creates host + Hyper-V inbound rules (required for WSL mirrored + `firewall=true`).
Includes inference RPC **`:31350`**. See docs/WINDOWS_WSL_DOCKER_ENGINE.md.
Verify from `apps`: `curl -fsS http://orchestrator/health`

---

## 3. Env files (required before first deploy)

Paths are relative to the **repo root**.

**Worker** — copy the machine template, then edit secrets:

```powershell
Copy-Item -Force `
  .\deploy\cluster-members\orchestrator\env.worker.example `
  .\deploy\petals\.env.worker

notepad .\deploy\petals\.env.worker
```

Set at minimum:

- `ALFA_BRAIN_URL=http://hub` — joining workers resolve DHT bootstrap via `GET .../api/petals/bootstrap` on the brain.
- `ALFA_WORKER_HEARTBEAT_TOKEN=` — **exactly** the same value as `ALFA_WORKER_HEARTBEAT_TOKEN` (or `ALFA_AI_API_TOKEN`) on **`hub`** `deploy/.env`. If this is empty, workers exit with **cannot resolve --initial_peers**.
- `HF_TOKEN=` / Hugging Face token if the model is gated (same idea as gateway).

Verify Compose passed env into the container (after `up -d`):

```powershell
docker inspect petals-worker-a --format '{{range .Config.Env}}{{println .}}{{end}}' | findstr ALFA_
```

You should see non-empty `ALFA_BRAIN_URL=` and `ALFA_WORKER_HEARTBEAT_TOKEN=`.

Optional: start from the SMB seed file instead of the example:

```powershell
Copy-Item -Force .\deploy\cluster-members\orchestrator\env.worker.example .\deploy\petals\.env.worker
```

**Gateway** — used by `docker-compose.petals-gateway.yml`. If missing, `deploy.ps1` creates a stub `deploy\.env.gateway`; you should still add tokens:

```powershell
Copy-Item -Force `
  .\deploy\cluster-members\orchestrator\env.gateway.example `
  .\deploy\.env.gateway

notepad .\deploy\.env.gateway
```

Fill `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN` if preload needs HF auth. Keep `ALFA_BRAIN_URL=http://hub` unless your brain URL differs.

**Dockge port (optional)** — `deploy.ps1` reads `ALFA_DOCKGE_HOST_PORT` from `deploy\.env` if that file exists (default **5002**).

---

## 4. Run deploy

From repo root, **PowerShell** (normal user is OK if Docker Desktop allows your account):

```powershell
cd C:/Users/operator\alfa-ai
Set-ExecutionPolicy -Scope Process Bypass
.\deploy\cluster-members\orchestrator\deploy.ps1
```

Single-GPU override (debug):

```powershell
$env:ALFA_NODE_PETALS_SINGLE_GPU = '1'
.\deploy\cluster-members\orchestrator\deploy.ps1
```

Gateway-only iteration (does not rebuild worker/Dockge):

```powershell
.\deploy\cluster-members\orchestrator\deploy-petals-gateway.ps1
```

---

## 5. Smoke checks (after deploy.ps1 succeeds)

If step **6 (Primary Petals gateway)** logged `alfa-petals-ml-base:cpu: not found`, **pull latest `main`** and re-run `deploy.ps1`: it now builds the CPU ml-base locally before gateway compose (gateway Dockerfile uses `FROM alfa-petals-ml-base:cpu`, which is not on Docker Hub).

If **`ml-base` CPU** build fails with **`grpcio-tools` vs `setuptools` dependency conflict**, the wheel hub still has **`setuptools==69.x`**. Refresh wheels: on hub run `bash scripts/seed-ml-base-wheels-hub.sh cpu`, then on `orchestrator` re-run `scripts/sync-petals-wheels-from-smb.ps1 -Variant cpu`. Or build ml-base once with **`PIP_OFFLINE=0`** (PyPI) then bring up the gateway compose.

If **`petals-worker-a` / `petals-worker-b` stay `Restarting`** and logs show **`cannot resolve --initial_peers`**: set **`ALFA_BRAIN_URL`** and **`ALFA_WORKER_HEARTBEAT_TOKEN`** in **`deploy\petals\.env.worker`** (token must match `hub` brain `deploy/.env`), then **`docker compose ... up -d --force-recreate`** from **`deploy\petals`** or re-run **`deploy.ps1`**. Pull latest **`main`** for entrypoint fixes (brain lookup uses Python **`urllib`**, not **`curl`**). HTTP **404** on bootstrap means no publisher yet — bring up **`apps`** bootstrap Petals worker.

```powershell
# Primary Petals gateway (LiteLLM frontier tier points here first)
Invoke-WebRequest -Uri 'http://orchestrator/health' -UseBasicParsing | Select-Object StatusCode, Content

# Worker monitor (dual-GPU: worker-a keeps MONITOR_PORT default 31331)
Invoke-WebRequest -Uri 'http://orchestrator/health' -UseBasicParsing | Select-Object StatusCode, Content

# Local Dockge UI
Start-Process 'http://127.0.0.1:5002/'
```

Worker logs:

```powershell
docker logs -f petals-worker-a
# or single-GPU:
# docker logs -f petals-worker
```

---

## 6. Optional — llama.cpp RPC tier (separate from Petals)

Mutually exclusive with Petals on the same GPU ports — see [docs/PORT_ASSIGNMENTS.md](../../../docs/PORT_ASSIGNMENTS.md) and [docs/LLAMACPP_RPC_OPERATOR.md](../../../docs/LLAMACPP_RPC_OPERATOR.md).

```powershell
.\deploy\cluster-members\orchestrator\deploy-llamacpp-rpc.ps1
```

---

## 7. Register worker with brain admin API

JWT required on `hub`. Example (run from WSL or any shell with `curl`):

```bash
curl -sS -X POST http://hub/alfa-ai/api/admin/workers \
  -H "Authorization: Bearer <JWT>" -H 'Content-Type: application/json' \
  -d '{"name":"win11-dockge","ip_address":"orchestrator","monitor_port":31331,"role":"gpu-worker"}'
```

See WORKER_ROLLOUT § Phase 2 for context.
