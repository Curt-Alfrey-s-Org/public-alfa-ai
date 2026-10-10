# First-Run Workers From `orchestrator`

Use this when `gaming-a`, `gaming-b`, `gaming-c`, `secondary` need repo/scripts staged from `orchestrator`
and **WSL Docker Engine** migration before Petals deploy.

**Mandatory checklist (every Windows worker):**
[WINDOWS_WSL_ROLLOUT_CHECKLIST.md](../../docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md)

**Rollout order (June 2026):** **`gaming-a` → `gaming-b` → `gaming-c` → `secondary`**

## 1) On `orchestrator` pull latest repo

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
```

## 2) On `orchestrator` stage cluster members to SMB hub

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
    C:/Users/operator\alfa-ai\scripts\stage-cluster-members.ps1
```

This syncs member folders, `_common\`, and `_common\repo\` to
`\\hub\temp\cluster_members\` (required for Blackwell worker deploy).

Optional lighter refresh (member folders only, **no** `_common\repo`):

```powershell
powershell -ExecutionPolicy Bypass -File `
    C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\publish-host-folders-to-smb.ps1
```

## 3) On each worker copy host folder local

```powershell
# gaming-a (step 2)
robocopy \\hub\temp\cluster_members\gaming-worker-a-219 C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-a /E

# gaming-b (step 3)
robocopy \\hub\temp\cluster_members\gaming-worker-b-249 C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-b /E

# gaming-c (step 4)
robocopy \\hub\temp\cluster_members\gaming-worker-c-59 C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-c /E
```

## 4) On each worker run repo install/update first

```powershell
# gaming-a
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-a\git-install-repo.ps1

# gaming-b
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-b\git-install-repo.ps1

# gaming-c
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-c\git-install-repo.ps1
```

Each script installs Git if missing, then clone/pulls `alfa-ai` into
`C:\alfa-ai-worker`.

## 5) WSL Docker Engine migration (each worker — before Petals deploy)

**Do this once per host.** Full phases in
[WINDOWS_WSL_ROLLOUT_CHECKLIST.md](../../docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md).

**Repo user (normal PowerShell):**

```powershell
cd C:\Users\YOURUSER\alfa-ai
git pull --ff-only origin main
copy deploy\cluster-members\_common\wslconfig-petals.example C:\Users\YOURUSER\.wslconfig
wsl --shutdown
wsl -d Ubuntu nvidia-smi
```

**Administrator (once per host — use full path to repo user's checkout):**

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\YOURUSER\alfa-ai\deploy\petals\02-install-docker-wsl-engine.ps1
. C:\Users\YOURUSER\alfa-ai\deploy\cluster-members\_common\open-petals-firewall.ps1
# Ports per host — see checklist port matrix
Open-AlfaPetalsWorkerFirewall -DisplayNamePrefix 'ALFa gaming-worker-a-219' -TcpPorts 31330,31331,5003 -Profile Any
# gaming-worker-b-249: 31330,31331,31360
# gaming-worker-c-59: 31330,31331,31351,11434
# ai-148: 31330,31331
```

## 6) On each worker run bootstrap with log capture

```powershell
# gaming-a
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-a\run-aria2-bootstrap-with-log.ps1

# gaming-b
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-b\run-aria2-bootstrap-with-log.ps1

# gaming-c
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-c\run-aria2-bootstrap-with-log.ps1
```

Logs land in each host folder: `deploy/cluster-members/<host>/logs/*.log`

## 7) Deploy Petals worker (per host — June 2026 order)

Each host folder has a **README + `build-start-*.ps1`** (firewall, deploy, smoke checks):

| Step | Host | README | One command |
|------|------|--------|-------------|
| 2 | `gaming-a` | [gaming-worker-a-219/README.md](gaming-worker-a-219/README.md) | `build-start-gaming-worker-a-219.ps1` |
| 3 | `gaming-b` | [gaming-worker-b-249/README.md](gaming-worker-b-249/README.md) | `build-start-gaming-worker-b-249.ps1` |
| 4 | `gaming-c` | [gaming-worker-c-59/README.md](gaming-worker-c-59/README.md) | `build-start-gaming-worker-c-59.ps1` |

Copy `env.worker.example` → `.env.worker` in that member folder; set `HF_TOKEN` +
`ALFA_WORKER_HEARTBEAT_TOKEN` (match `hub` brain). See
[docs/petals/PER_HOST_ENV_TEMPLATES.md](../../docs/petals/PER_HOST_ENV_TEMPLATES.md).

From **normal user PowerShell** (local git checkout):

```powershell
cd C:\Users\YOURUSER\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File `
    .\deploy\cluster-members\gaming-worker-a\build-start-gaming-worker-a-219.ps1
# then gaming-worker-b-249, then gaming-worker-c-59
```

## 8) Post-startup gate (required after each deploy)

Use **one WSL session** with warm-up so throughput benchmark can finish:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\_common\run-post-startup-status-with-log.ps1 `
  -HostProfile gaming-worker-a-219 -WarmUpSec 180
# HostProfile: gaming-worker-a-219 | gaming-worker-b-249 | gaming-worker-c-59 | ai-148
```

Require **`RESULT: OK`**. Log on `inference` hub: `logs/cluster-status/`.

Remote LAN verify from `apps` (see checklist Phase E).

Uninstall Docker Desktop (Admin, Phase F) only after post-startup + remote verify green.

## 9) Remaining swarm members (`hub`, `apps`, `secondary`, …)

Use the full checklist in [docs/petals/WORKER_ROLLOUT.md](../../docs/petals/WORKER_ROLLOUT.md) and the README under each `deploy/cluster-members/<host>/` folder. **Blackwell** Linux/Scale hosts use `docker-compose.worker.blackwell.yml`; **Ampere/Turing** hosts use `docker-compose.worker.yml` (see **ai-148** for Linux bare-metal).
