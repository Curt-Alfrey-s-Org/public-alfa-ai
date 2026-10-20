# April 2026 hardware swap — post-install runbook

> **Historical (hardware swap only).** Model routing has since moved on — the
> May-2026 rebalance retired the CPU MoE; tiers 0/1/2 = `qwen3:32b` on `gaming-c`.
> See [QWEN3_MIGRATION.md](../QWEN3_MIGRATION.md). This runbook covers only the
> physical GPU swap/rebuild commands.
>
> Originally written as a companion to the `cluster-rebalance-111-moe`
> PR (now merged to `main` — May 2026). All config files on `main` are
> pinned to the current target state (e.g.
> `PETALS_WORKER_COMPOSE=docker-compose.worker.blackwell.yml` on `hub`,
> `docker-compose.worker.dual-gpu.yml` layered on `orchestrator`). This runbook is
> the exact command set to execute on each host **the day its physical
> GPU swap / rebuild actually lands**. Do NOT run the `docker compose up`
> steps here before the hardware is in place — Blackwell (`sm_120`) kernels
> fail to load on Ampere (`sm_86`) cards with
> `CUDA error: no kernel image is available for execution on the device`.

## Prerequisites

Across all hosts:

- Branch `main` pulled on the host's repo clone
  (or mirrored via `\\hub\temp\cluster_members\...` for Windows).
- `.env.worker` for that host — start from `deploy/cluster-members/<member>/env.worker.example`
  ([PER_HOST_ENV_TEMPLATES.md](petals/PER_HOST_ENV_TEMPLATES.md)), then set HF_TOKEN and ALFA_WORKER_HEARTBEAT_TOKEN.
- hub hub (`\\hub\...`) reachable on the LAN.

Per-host sanity check before ANY swap-day compose-up:

```bash
# Linux (hub, apps, secondary-if-linux)
nvidia-smi --query-gpu=index,name,compute_cap,memory.total --format=csv
```

```powershell
# Windows (orchestrator, gaming-c, gaming-a, gaming-b, secondary-if-windows)
nvidia-smi --query-gpu=index,name,compute_cap,memory.total --format=csv
```

Confirm the reported `compute_cap` + `memory.total` match the target in the
section below before proceeding.

---

## Host `hub` — RTX 3060 12 GB → RTX 5060 8 GB (Blackwell, cc 12.0)

**Target state after swap:** single GPU reports `8.0 GB` total VRAM and
`compute_cap=12.0`. Petals worker announces on `orchestrator` with
the Blackwell image.

**Already staged on `hub`:**

- `/mnt/HDDs/Alfa-AI/repo/alfa-ai` on branch `main`.
- `deploy/cluster-members/hub/.env.worker` created from
  [env.worker.example](../deploy/cluster-members/hub/env.worker.example)
  with `PETALS_WORKER_COMPOSE=docker-compose.worker.blackwell.yml` + HF/heartbeat
  tokens seeded from `deploy/.env`.
- `/mnt/cluster` symlink → `/mnt/HDDs/Alfa-AI` and
  `/mnt/cluster/petals/{identity,bootstrap}` present.

**Swap day (SSH to `hub` as `operator`):**

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
git pull --ff-only origin main

# 1. Verify new GPU reports Blackwell
nvidia-smi --query-gpu=index,name,compute_cap,memory.total --format=csv
#    Expect: NVIDIA GeForce RTX 5060, 12.0, ~8192 MiB

# 2. Sync cuda-blackwell wheels + bring up the worker (deploy.sh does both
#    + NFS-mount layering + registry-mirror + brain stack idempotent):
sudo bash deploy/cluster-members/hub/deploy.sh --skip-images

# 3. Smoke test
sudo docker logs --tail 100 petals-worker 2>&1 | grep -E 'Running a server|Announced that blocks'
curl -fsS http://127.0.0.1:31331/health
curl -fsS http://orchestrator/health 2>/dev/null | jq '.reachable_peers, .loaded_models'
```

**Rollback (if Blackwell image won't load):**

```bash
# Flip back to the standard CUDA compose until the wheel / driver issue is
# resolved. The 5060 driver must be >= 570.x for sm_120 CUDA 12.8 kernels.
sed -i 's|^PETALS_WORKER_COMPOSE=.*|PETALS_WORKER_COMPOSE=docker-compose.worker.yml|' \
    deploy/cluster-members/hub/.env.worker
sudo bash deploy/cluster-members/hub/deploy.sh --skip-images
```

---

## Host `orchestrator` — platform rebuild (7900X/X870E/DDR5) + 1× → 2× RTX 3060 12 GB

**Target state after rebuild:** `nvidia-smi -L` reports two RTX 3060 entries,
both cc 8.6 / 12 GB. Two Petals workers up (`petals-worker-a` GPU 0 :31330,
`petals-worker-b` GPU 1 :31340), primary Petals gateway on `:8013`, Dockge
on `:5002`, llama.cpp `rpc-server :31350` pinned to GPU 0.

**Already on the `orchestrator` SMB deploy stage after `orchestrator` git-pulls this branch
and `orchestrator` reruns `scripts/stage-cluster-members.ps1`:**

- `deploy/petals/docker-compose.worker.dual-gpu.yml` (new override).
- `deploy/cluster-members/orchestrator/deploy.ps1` with auto-detect
  (`nvidia-smi -L` >= 2 GPUs ⇒ dual-GPU override auto-layered).
- `deploy/llamacpp-rpc/.env.rpc.example` defaults `CUDA_VISIBLE_DEVICES=0`.

**Swap day (Admin PowerShell on `orchestrator`):**

```powershell
# 1. Pull repo + re-stage the cluster-members tree on the SMB hub
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
.\scripts\stage-cluster-members.ps1

# 2. Verify both 3060s are visible to Windows + WSL/Docker
nvidia-smi -L
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi -L
#    Expect two "GPU 0: NVIDIA GeForce RTX 3060" / "GPU 1: ..." lines in both.

# 3. Open inbound firewall for worker-b's DHT + monitor ports
New-NetFirewallRule -DisplayName 'Petals worker-b DHT 31340' `
    -Direction Inbound -Protocol TCP -LocalPort 31340 -Action Allow
# (Monitor 31341 is loopback only -- no firewall rule needed.)

# 4. Run the deploy script. Dual-GPU auto-detect kicks in because
#    nvidia-smi -L now shows 2 GPUs.
.\deploy\cluster-members\orchestrator\deploy.ps1

# 5. Smoke test
docker ps --filter name=petals-worker --format 'table {{.Names}}\t{{.Status}}'
docker logs --tail 80 petals-worker-a 2>&1 | Select-String 'Running a server|peer_id'
docker logs --tail 80 petals-worker-b 2>&1 | Select-String 'Running a server|peer_id'
#    Peer-ids in the two logs MUST differ.
curl.exe -fsS http://127.0.0.1:8013/health | ConvertFrom-Json |
    Select-Object reachable_peers, loaded_models
```

**Force single-worker fallback (if one GPU fails post-rebuild):**

```powershell
# Brings up only the base petals-worker service on GPU 0 until GPU 1 is fixed.
$env:ALFA_NODE_PETALS_SINGLE_GPU = '1'
.\deploy\cluster-members\orchestrator\deploy.ps1
```

**Confirm `rpc-server :31350` stays on GPU 0 only:**

```powershell
docker exec llamacpp-rpc-server printenv CUDA_VISIBLE_DEVICES
#    Expect: 0
```

---

## Host `gaming-c` gaming-worker-c — RTX 5060 8 GB → RTX 5070 12 GB (still Blackwell)

**Target state after swap:** `nvidia-smi` reports RTX 5070 / 12 GB. The
existing Blackwell worker auto-uses the extra VRAM
(`PETALS_NUM_BLOCKS=auto`) — no compose change.

**Swap day (Admin PowerShell on `gaming-c`):**

```powershell
# 1. Verify new card
nvidia-smi --query-gpu=name,compute_cap,memory.total --format=csv

# 2. Force-recreate the existing Petals worker so it re-reads VRAM at startup
docker compose -f C:\alfa-ai-worker\deploy\petals\docker-compose.worker.blackwell.yml `
               -f C:\alfa-ai-worker\deploy\petals\docker-compose.worker.smb-hf.override.yml `
               --env-file C:\alfa-ai-worker\deploy\petals\.env.worker `
               up -d --force-recreate petals-worker

# 3. Confirm the block count went up (previously ~9 blocks on 8 GB, expect
#    more on 12 GB)
docker logs --tail 80 petals-worker 2>&1 | Select-String 'blocks|assigned'
```

No remote re-staging required — `gaming-c`'s compose files already target
Blackwell.

---

## Host `secondary` — new node, GTX 1660 Super 6 GB (Turing cc 7.5)

**Target state after install:** host on LAN as `orchestrator`, running a
single Petals worker on `standard CUDA 12.4` image announcing on
`orchestrator`.

**Install day (on `secondary`, Admin PowerShell or bash depending on OS):**

```powershell
# Windows path (preferred; mirrors gaming-worker-a-219)
# 0. Rename the placeholder folder to the actual hostname on orchestrator's repo,
#    commit, push, re-pull here. Before that:
#      (on orchestrator)  git mv deploy/cluster-members/worker-secondary `
#                       deploy/cluster-members/<actual-hostname>-248
#      (on orchestrator)  # edit $MachineName in deploy.ps1 to match
#      (on orchestrator)  git commit -am "rename worker-248 -> <hostname>-248"
#      (on orchestrator)  git push ; .\scripts\stage-cluster-members.ps1

# 1. Map SMB shares (admin PowerShell, once)
net use Y: \\hub\petals-wheels /PERSISTENT:YES
net use Z: \\hub\huggingface   /PERSISTENT:YES

# 2. Edit .env.worker on the SMB share with HF_TOKEN +
#    ALFA_WORKER_HEARTBEAT_TOKEN (from hub deploy/.env)

# 3. Firewall open
New-NetFirewallRule -DisplayName 'Petals DHT 31330' `
    -Direction Inbound -Protocol TCP -LocalPort 31330 -Action Allow

# 4. Deploy
powershell -NoProfile -ExecutionPolicy Bypass -File `
    \\hub\temp\cluster_members\<hostname>-248\deploy.ps1

# 5. Smoke test
docker logs --tail 80 petals-worker 2>&1 | Select-String 'Running a server'
curl.exe -fsS http://127.0.0.1:31331/health
```

```bash
# Linux fallback (if secondary runs Ubuntu/Debian)
sudo bash deploy/cluster-members/<hostname>-248/deploy.sh
```

**Do NOT use the Blackwell image on `secondary`** — GTX 1660 Super is Turing
(`sm_75`) and `sm_120` kernels won't load. `nvidia-preflight.ps1` auto-
selects `docker-compose.worker.yml` for cc 7.x, so the deploy script
picks the right image automatically; just don't hand-override to the
Blackwell compose.

---

## Cluster-wide acceptance (run after all four swap days complete)

From any host that can reach the LAN:

```bash
# 1. Primary gateway on orchestrator sees all 8 Petals GPUs across 7 hosts
curl -fsS http://orchestrator/health \
  | jq '.reachable_peers, .loaded_models, .supported_models'
#    Expect: reachable_peers >= 6, loaded_models includes llama3.3-70b-instruct

# 2. Tier-3a (frontier-chat) end-to-end smoke via the brain LiteLLM
curl -fsS -X POST http://hub/v1/chat/completions \
  -H 'Authorization: Bearer sk-alfa-...' -H 'Content-Type: application/json' \
  -d '{"model":"llama3.3-70b-instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'

# 3. Tier-3b (frontier-code) RPC coordinator on gaming-b:31360
curl -fsS -X POST http://orchestrator/v1/chat/completions \
  -H 'Authorization: Bearer change-me' -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-coder-next-80b-a3b","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'

# 4. Brain admin health surfaces all 7 hosts
TOKEN='change-me'
curl -fsS -H "Authorization: Bearer $TOKEN" \
  http://hub/alfa-ai/api/admin/health \
  | jq '.workers[] | {name: .payload.worker_name, reachable, age_sec}'
```

**Gate:** all four checks green before closing this PR's follow-up
hardware-acceptance checklist.

---

## Summary table — what's staged vs swap-day gated

| Host  | Config staged? | Blocked by hardware? | Swap-day commands |
|-------|----------------|----------------------|-------------------|
| `hub` | yes (`.env.worker`, NFS dirs, wheel hub) | yes — 3060 still in box | deploy.sh on this doc |
| `orchestrator`  | partial (branch on `apps` pushed) | yes — platform + 2nd 3060 swap | deploy.ps1 on this doc |
| `gaming-c`  | yes (no compose change needed) | yes — 5060→5070 swap | force-recreate on this doc |
| `secondary` | placeholder folder scaffolded | yes — host doesn't exist yet | rename + deploy.ps1 |
| `apps` | nothing to do (last-resort gateway unchanged) | no | — |
| `gaming-b` | nothing to do | no | — |
| `gaming-a` | nothing to do | no | — |
