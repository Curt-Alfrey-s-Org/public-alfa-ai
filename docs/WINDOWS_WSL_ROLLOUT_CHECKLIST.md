# Windows WSL Docker rollout checklist (Petals cluster)

Operator checklist distilled from **`orchestrator` (June 2026)** — apply on **every**
Windows Petals host **before** repeating Docker Desktop-era mistakes.

**Hosts:** `orchestrator` operator (**WSL + Desktop removed 2026-06-08**), `gaming-a` gaming-worker-a,
`gaming-b` gaming-worker-b, `gaming-c` gaming-worker-c, `secondary` worker (Linux — no Desktop).

**Dockge tie-in:** after Phase F on each Windows host, run
[DOCKGE_AGENTS_WORKERS.md](DOCKGE_AGENTS_WORKERS.md) § *Post-uninstall Docker CLI + Dockge*
and confirm the agent is **Online** on `orchestrator` primary (`http://127.0.0.1:5002`).

**Deep dive:** [WINDOWS_WSL_DOCKER_ENGINE.md](WINDOWS_WSL_DOCKER_ENGINE.md)  
**Swarm order:** [petals/WORKER_ROLLOUT.md](petals/WORKER_ROLLOUT.md)  
**Account split (`orchestrator`):** [.cursor/rules/windows-win11-cluster-operator.mdc](../.cursor/rules/windows-win11-cluster-operator.mdc)

---

## Lessons learned (do not skip)

| Mistake | Symptom | Fix |
|---------|---------|-----|
| `.wslconfig` on **admin** user, not **repo owner** | Mirrored mode inactive for daily `wsl` | Install script writes repo owner's file; verify `C:\Users\<repo>\.wslconfig` |
| Missing **`hostAddressLoopback=true`** | Windows curl to LAN IP works; remote LAN fails | `[experimental]` block in `.wslconfig` |
| Missing **`vmIdleTimeout=-1`** / **`instanceIdleTimeout=-1`** | Post-startup OK locally; `apps`/`hub` timeout minutes later | Keep WSL VM alive without open terminal |
| Host firewall only (`New-NetFirewallRule`) | Same-host `orchestrator` OK; remote `apps` timeout | **`New-NetFirewallHyperVRule`** via `open-petals-firewall.ps1` |
| Post-startup via **PowerShell `Start-Sleep`** then separate `wsl` | Cold WSL boot; containers "Up 2 seconds" | **One** `wsl -e bash -lc "sleep N && …post-startup…"` |
| Gateway probe **`127.0.0.1:8013`** on `orchestrator` | False FAIL (gateway is `:8413`) | Profile uses `docker exec` + LAN publish check |
| **`127.0.0.1` curl from WSL** for gateway | Timeout under mirrored mode | Probe via `docker exec` or Windows `Invoke-WebRequest` |
| Deploy before **throughput benchmark** (~60s) | Monitor `degraded`, gateway `(health: starting)` | Wait 2–3 min in same WSL session before gate |
| **`networkingMode=mirrored` on Win10** | WSL warns and falls back to NAT; remote `apps` cannot reach `:31330` | Use **`wslconfig-petals-win10-nat.example`** + **`install-wsl-nat-portproxy.ps1`** |
| Docker Desktop uninstalled but **`docker_data.vhdx` left behind** | C: silently fills (`orchestrator`: 294 GB orphan → 88 MB free); WSL `getpwnam … failed (EIO)` | Phase H: delete `…\AppData\Local\Docker\wsl\disk\docker_data.vhdx` after confirming no `docker-desktop*` distro in `wsl -l -v` |
| Worker **builds `ml-base` locally** (`docker compose build`) | 10–30 min build; 50+ GB build cache + `ml-base` images per host | Phase H: build per-variant on `hub`, `docker load` the tarball, never build on workers |

---

## Per-host port matrix (firewall + Hyper-V)

| Host | Profile | LAN IP | Inbound TCP (firewall + Hyper-V) | Notes |
|------|---------|--------|----------------------------------|-------|
| `orchestrator` | `operator-93` | `orchestrator` | `8413`, `5002`, `31330`, `31340`, `31331`, `31341`, **`31350`** | Primary gateway `:8413`; inference RPC shard |
| `gaming-a` | `gaming-worker-a-219` | `orchestrator` | `31330`, `31331`, `5003` | **Win10:** portproxy + host firewall (no Hyper-V) |
| `gaming-c` | `gaming-worker-c-59` | `orchestrator` | `31330`, `31331`, `31351`, `11434` | RPC tier 3b `:31351`; Ollama embed |
| `gaming-b` | `gaming-worker-b-249` | `orchestrator` | `31330`, `31331`, `31360` | RPC coordinator `:31360` |
| `inference` ai-148 | `ai-148` | `orchestrator` | `31330`, `31331` | Linux native Docker (not WSL) |

Monitors `:31331` are loopback-oriented; opening them on LAN is optional (brain polling).

Authoritative map: [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md).

---

## Phase A — Repo user (normal PowerShell)

```powershell
cd C:\Users\<YOU>\alfa-ai
git pull --ff-only origin main
. .\deploy\cluster-members\_common\Test-AlfaWindowsDeployPortPreflight.ps1
Test-AlfaWindowsDeployPortPreflight -Profile <profile>   # operator-93 | gaming-worker-a-219 | …
```

Copy [wslconfig-petals.example](../deploy/cluster-members/_common/wslconfig-petals.example)
to `C:\Users\<YOU>\.wslconfig`, then:

```powershell
wsl --shutdown
wsl -d Ubuntu docker ps
wsl -d Ubuntu nvidia-smi
```

---

## Phase B — Administrator (install + firewall once)

**Do not `git pull` here.** Use full path to the **repo user's** checkout.

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\<YOU>\alfa-ai\deploy\petals\02-install-docker-wsl-engine.ps1 -HostProfile operator-93
```

Firewall (host + Hyper-V -- idempotent; included in install when `-HostProfile` is set):

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\<YOU>\alfa-ai\deploy\cluster-members\_common\install-wsl-lan-firewall.ps1 -Profile operator-93
```

Example profiles: `operator-93`, `gaming-worker-a-219`, `gaming-worker-c-59`, `gaming-worker-b-249`.

---

## Phase C — Deploy (repo user)

```powershell
cd C:\Users\<YOU>\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\<member>\build-start-*.ps1
```

Close Cursor Remote-SSH / port forwards that steal `:31331` during deploy.

---

## Phase D — Post-startup gate (repo user, one WSL session)

Use **`-WarmUpSec 180`** so WSL stays warm through the throughput benchmark:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\_common\run-post-startup-status-with-log.ps1 `
  -HostProfile <profile> -WarmUpSec 180
```

Require **`RESULT: OK`** in output. Log lands on `inference` hub at
`/home/operator/alfa-ai/logs/cluster-status/`.

---

## Phase E — Remote LAN verify (from `apps`)

```bash
curl -fsS --max-time 5 http://<LAN_IP>:8413/health    # orchestrator gateway only
timeout 3 bash -c "echo >/dev/tcp/<LAN_IP>/31330" && echo DHT_OK
```

Same-host Windows curl is **not** sufficient — always probe from `apps` or `hub`.

---

## Phase F — Uninstall Docker Desktop (admin, after Phase D + E green)

**Prerequisite:** `wsl -d Ubuntu docker ps` shows Petals/Dockge containers healthy.
**Do not `git pull` in admin session** — script path must exist on disk from repo user's
last `git pull`.

| Host | Admin account | Uninstall script path |
|------|---------------|---------------------|
| `orchestrator` | `operator` or elevated `operator` | `C:/Users/operator\alfa-ai\deploy\petals\99-uninstall-docker-desktop.ps1` |
| `gaming-a` | Administrator | `C:\alfa-ai-worker\deploy\petals\99-uninstall-docker-desktop.ps1` |
| `gaming-b` | Administrator | `C:\alfa-ai-worker\deploy\petals\99-uninstall-docker-desktop.ps1` |
| `gaming-c` | Administrator | `C:\alfa-ai-worker\deploy\petals\99-uninstall-docker-desktop.ps1` |

```powershell
cd <path-from-table-above>   # parent of deploy\petals\
Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
powershell -ExecutionPolicy Bypass -File .\deploy\petals\99-uninstall-docker-desktop.ps1
```

Wait **10 seconds** at the countdown — do **not** Ctrl+C. Then:

```powershell
wsl --shutdown
```

### Phase F verify (repo user, same host)

```powershell
Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"   # False
wsl -d Ubuntu docker ps
. <repo>\deploy\cluster-members\_common\initialize-windows-deploy.ps1
Initialize-AlfaDockerCli   # must say: Docker CLI: WSL (Ubuntu)
```

### Phase G — Dockge stacks (repo user, after Phase F)

| Host | Action |
|------|--------|
| **`orchestrator`** | `reconcile-dockge-stacks.ps1` — **Current** shows `petals-worker`, `petals-gateway` |
| **`gaming-a` / `gaming-b` / `gaming-c`** | `build-start-*.ps1` or `run.ps1` — agent **Online** on `orchestrator` primary |

See [DOCKGE_AGENTS_WORKERS.md](DOCKGE_AGENTS_WORKERS.md) § *Windows hosts — remove Docker Desktop*.

---

## Phase H — Storage hygiene + build from `hub` (every host, after Phase F)

**Policy (all hosts identical):** heavy image builds happen **only on `hub`**
(or `apps`), **once per hardware variant**; every worker is a **pure consumer**
that `docker load`s its matching tarball and **never builds locally**. Full
runbook: **[operations/STORAGE_CLEANUP_AND_BUILD_OFFLOAD.md](operations/STORAGE_CLEANUP_AND_BUILD_OFFLOAD.md)**.

**H1. Reclaim the orphaned Docker Desktop disk** (after Phase F uninstall):

```powershell
wsl -l -v                                  # confirm ONLY Ubuntu (no docker-desktop*)
$o = "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"
if (Test-Path $o) { Remove-Item -Force $o }   # 294 GB on orchestrator; never delete the Ubuntu ext4.vhdx
```

**H2. Per-host variant (which tarball this host loads):**

| Host(s) | GPU class | Variant | Worker tarball |
|---------|-----------|---------|----------------|
| `orchestrator`, `secondary` | Ampere / Turing (RTX 30xx, GTX 16xx) | `cuda` | `alfa-petals-worker-gpu-12.4.1-cuda-runtime.tar.gz` |
| `gaming-a`, `gaming-b`, `gaming-c` | Blackwell (RTX 50xx, sm_120) | `cuda-blackwell` | `alfa-petals-worker-gpu-12.8.0-cuda-blackwell.tar.gz` |

`nvidia-preflight.ps1` selects the variant automatically (`ALFA_NODE_GPU_CLASS`).

**H3. Build + publish on `hub` (operator, once per variant):**

```bash
ssh operator@hub && cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo bash scripts/build-worker-image-on-hub.sh cuda            # Ampere/Turing hosts
sudo bash scripts/build-worker-image-on-hub.sh cuda-blackwell  # Blackwell hosts
ls -lh /mnt/HDDs/Alfa-AI/docker-images/*.tar.gz                # verify present
```

**H4. Reclaim local build artifacts** (after a healthy no-build deploy):

```powershell
wsl -d Ubuntu -- docker image rm alfa-petals-ml-base:cuda alfa-petals-ml-base:cpu 2>$null
wsl -d Ubuntu -- docker builder prune -af      # workers no longer build
# wheel caches: clear deploy/petals/build-contexts/wheels-*/*.whl (keep .gitkeep)
wsl --shutdown                                  # then compact ext4.vhdx (Optimize-VHD/diskpart)
```

Keep runtime images only (`alfa-petals-worker-gpu:*`, `alfa-ai-petals-gateway:local`,
`louislam/dockge`, `python:3.12-slim`). **Acceptance:** `docker system df` shows
~0 build cache and no `ml-base`; deploy pulls nothing from pypi.org / pytorch.org.

---

## Rollout order (June 2026)

| Step | Host | Phases | Desktop removed? | Build offload (Phase H) |
|------|------|--------|------------------|-------------------------|
| 1 | **`orchestrator`** | A–H | **Yes** | Orphan VHD deleted (294 GB) 2026-06-19; switch to no-build pending hub tarballs |
| 2 | **`gaming-a`** | A–E → F → G → H | Pending | Pending |
| 3 | **`gaming-b`** | A–E → F → G → H | Pending | Pending |
| 4 | **`gaming-c`** | A–E → F → G → H (+ Ollama embed after Petals green) | Pending | Pending |
| 5 | **`secondary`** | Linux deploy only (no Phase F); Phase H applies | N/A | Pending |

Update [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md) after each host passes Phase E.
Mark Desktop removed in [DOCKGE_AGENTS_WORKERS.md](DOCKGE_AGENTS_WORKERS.md) fleet status table when Phase F verify is green.
