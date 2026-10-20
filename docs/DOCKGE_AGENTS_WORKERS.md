# Unified Dockge control plane (primary + agents)

Single operator UI for every Docker Compose stack in the cluster. Primary Dockge on **`orchestrator`** displays stacks on **`pool-opt-in`**, **`market`**, **`atems`**, **`apps`**, **`probilliards`**, **`monitor`**, **`hub`**, **`inference`**, **`gaming-b`**, **`gaming-c`**, **`gaming-a`** without per-host browser tabs.

## Roles

| Node | Role | Dockge role | Port |
|------|------|-------------|------|
| **`orchestrator`** (Win11) | Primary Dockge UI + Petals workers + primary gateway | **primary** (+ agent) | 5002 |
| **`pool-opt-in`** (ALFA-AI VM) | GPU embed + rerank sidecars | agent | 5001 |
| **`market`** (MARKET VM) | market-pie5-bot | agent | 5001 |
| **`atems`** (ATEMS VM) | atems | agent | 5001 |
| **`apps`** (Ubuntu) | Apps host (Postgres, Redis, bots, bootstrap worker, last-resort gateway) | agent | 5001 |
| **`probilliards`** (ProBilliards VM) | rankings-bot + USPBF | agent | 5001 |
| **`monitor`** (Grafana VM) | monitoring stack | agent | 5001 |
| **`rag`** (VM110 CPU RAG) | CPU embed + rerank | agent | 5001 |
| **`hub`** (hub) | Brain + hub (registry, NFS models) | agent | **31014** (hub Apps) |
| **`inference`** (ai-148) | inference shards (RTX 5060 + RTX 3060); Petals optional | agent | 5001 |
| **`secondary`** (`gpu-248`) | inference GTX 1070 shard (opt-in) | agent | 5001 |
| **`solar-broker`** (pi4 Victron) | HA / Victron edge | agent | **5006** (`pi4-dockge`) |
| **`gaming-b`** (gaming-worker-b) | Petals worker (RTX 5070 Blackwell) — **offline** | agent | 5001 |
| **`gaming-c`** (gaming-worker-c) | Petals worker (RTX 5070 Blackwell) — **offline** | agent | 5001 |
| **`gaming-a`** (gaming-worker-a) | Dockge worker (RTX 5060 Blackwell); optional RPC when idle | agent | **5003** (not 5001 — GT3 mobile service on Win10) |

## How it works

1. Every node runs `louislam/dockge:1` with `DOCKGE_STACKS_DIR=/opt/stacks` (Linux) or `C:\alfa-ai-worker\stacks` (Windows).
2. Stacks appear when `/opt/stacks/<name>` contains compose files. Per-host deploy scripts symlink repo paths into `/opt/stacks` so Compose project names match Dockge folder names.
3. Primary UI adds each agent under **Settings → Remote agents** (`http://<lan-ip>:<port>/`).

### Visibility without ownership

Dockge only lists stacks whose `compose.yaml` (or `docker-compose.yml`) lives under
`DOCKGE_STACKS_DIR`. Containers started from other paths do not appear. To **show**
existing app stacks without changing how they are operated:

1. `mkdir -p /opt/stacks`
2. `ln -sfn <repo-checkout> /opt/stacks/<stack-name>` (one symlink per compose project)
3. In the primary UI, use **Scan Stacks Folder** (top-right menu) after symlinks change

The symlink does not move code or change deploy ownership — apps keep their own scripts;
Dockge gains read/manage visibility only.

## Project name rule

Compose derives the project name from the parent folder. If the project name does not match the symlink folder, Dockge shows "not managed by Dockge". Each host deploy script (`deploy/cluster-members/*/deploy.{sh,ps1}`) `cd`s into `/opt/stacks/<name>` before `docker compose up`.

## Primary Dockge on `orchestrator` (`:5002`)

Image: `louislam/dockge:1` from hub tarball
`\\hub\docker-images\louislam-dockge-1.tar.gz` (seeded from `inference` which
already had the image). Do **not** `docker pull` from Docker Hub on workers.

**Start / restart the UI only** (does not touch inference shards or coordinator):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaDockgePrimary.ps1
```

Start/deploy scripts write `dockge.local.env` next to
`deploy/cluster-members/_common/dockge/docker-compose.dockge.yml` (host bind
paths such as `DOCKGE_DATA_HOST`). That filename is gitignored at any level
([gitignore](https://git-scm.com/docs/gitignore)); do not commit a host copy.

Official install uses host **5001** mapped to container **5001**
([louislam/dockge](https://github.com/louislam/dockge/)). This cluster maps
**`orchestrator` host 5002 -> container 5001** so it does not collide with worker agents
on `:5001`.

**Do not** run `reconcile-dockge-stacks.ps1` while inference is up. That script
historically also ran `docker compose up` on `llamacpp-rpc`, which breaks the
single-client RPC session. Stack folder staging is included in
`Start-AlfaDockgePrimary.ps1` without starting the shard.

## Bring-up order

1. **`hub`** (hub): `deploy/cluster-members/hub/deploy.sh` — registry mirror, brain stack, hub NFS.
2. **`apps`** (apps): `deploy/cluster-members/apps/deploy.sh` — reads `stacksapps.yml` (Postgres, Redis, petals-worker, gateway, bots).
3. **`orchestrator`** (primary UI): `deploy/cluster-members/orchestrator/deploy.ps1` — primary Dockge, dual GPU workers, primary gateway `:8413`.
4. **`gaming-b` / `gaming-c` / `gaming-a`**: `deploy/cluster-members/<host>/deploy.ps1` — stage from `orchestrator` via `scripts/stage-cluster-members.ps1` when needed.

## Agent URLs (paste on `orchestrator` primary → Settings → Remote agents)

| Host | URL | Status |
|------|-----|--------|
| `pool-opt-in` | `http://orchestrator` | register after deploy |
| `market` | `http://market` | register after deploy |
| `atems` | `http://atems` | register after deploy |
| `apps` | `http://apps` | existing |
| `probilliards` | `http://orchestrator` | register after deploy |
| `monitor` | `http://monitor` | register after deploy |
| `rag` | `http://orchestrator` | register after deploy |
| `hub` | `http://hub` | existing |
| `inference` | `http://orchestrator` | existing |
| `solar-broker` | `http://orchestrator` | existing (`pi4-dockge`) |
| `secondary` | `http://orchestrator` | register after deploy |
| `gaming-b` | `http://orchestrator` | **offline** — register when host is back |
| `gaming-c` | `http://orchestrator` | **offline** — register when host is back |
| `gaming-a` | `http://orchestrator` | **online** — register on `orchestrator` primary if not yet listed |

Linux agents need `DOCKGE_AGENT_BIND_ADDR=0.0.0.0` in `.env.dockge` so `orchestrator` can reach them (restrict `:5001` with UFW to `orchestrator/24`).
Install via `deploy/cluster-members/_common/install-dockge-agent-linux.sh` (loads
`louislam-dockge-1.tar.gz` from `~/alfa-ai-cache/docker-images/` or `/mnt/cluster`;
never `docker pull`).

## Windows hosts — remove Docker Desktop (required for Dockge + Petals)

Dockge and Petals on Windows **must** run on **WSL Ubuntu Docker Engine**, not Docker
Desktop. After Desktop uninstall, `docker` is **not** on Windows PATH — use
`Initialize-AlfaDockerCli` (routes `docker` through WSL) or `wsl -d Ubuntu docker …`.

**Linux hosts (`apps`, `hub`, `inference`)** — no Docker Desktop; skip this section.

### Fleet status

| Host | OS | Repo / worker root | Desktop removed? | WSL Docker? | Dockge role |
|------|-----|-------------------|------------------|-------------|-------------|
| **`orchestrator`** | Win11 | `C:/Users/operator\alfa-ai` | **Yes** (2026-06-08) | Yes | **Primary** `:5002` |
| **`pool-opt-in`** | Ubuntu VM | `/home/operator/alfa-ai` | N/A | native docker | Agent `:5001` |
| **`market`** | Ubuntu VM | `/home/operator/market-pie5-bot` | N/A | native docker | Agent `:5001` |
| **`atems`** | Ubuntu VM | `/home/operator/atems` | N/A | native docker | Agent `:5001` |
| **`apps`** | Ubuntu VM | `/home/operator/alfa-ai` | N/A | native docker | Agent `:5001` |
| **`probilliards`** | Ubuntu VM | `/home/operator/rankings-bot`, `/home/operator/USPBF` | N/A | native docker | Agent `:5001` |
| **`monitor`** | Ubuntu VM | `/home/operator/monitoring` | N/A | native docker | Agent `:5001` |
| **`hub`** | hub | `/mnt/HDDs/Alfa-AI/repo/alfa-ai` | N/A | native docker | Agent `:31014` (Apps) |
| **`inference`** | Linux | `~/alfa-ai` | N/A | native docker | Agent `:5001` |
| **`gaming-a`** | Win10 | `C:\Users\Corey\alfa-ai` | **Yes** | Yes | Agent `:5003` (**online**) |
| **`gaming-b`** | Win11 | `C:\alfa-ai-worker` | Pending | Migrate first | Agent `:5001` (**offline**) |
| **`gaming-c`** | Win11 | `C:\alfa-ai-worker` | Pending | Migrate first | Agent `:5001` (**offline**) |

Canonical rollout: [WINDOWS_WSL_ROLLOUT_CHECKLIST.md](WINDOWS_WSL_ROLLOUT_CHECKLIST.md)
(Phases A–F). **Do not uninstall Desktop until Phases D + E pass** (WSL stack healthy
+ LAN verify from `apps`).

### Per-host order (after `orchestrator`)

1. **`gaming-a` gaming-worker-a** — WSL migrate → post-startup green → uninstall Desktop → redeploy → register agent on `orchestrator`
2. **`gaming-b` gaming-worker-b** — same
3. **`gaming-c` gaming-worker-c** — same (+ Ollama embed tier after Petals green)

### Phase F — uninstall Docker Desktop (Administrator PowerShell)

**No `git pull` in admin session** — use full path to the repo user's checkout.

```powershell
# Example gaming-a — adjust path per host (see table above)
Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"   # expect True before
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\petals\99-uninstall-docker-desktop.ps1
# Wait 10s — do not Ctrl+C during countdown
wsl --shutdown
```

`orchestrator` path (reference): `C:/Users/operator\alfa-ai\deploy\petals\99-uninstall-docker-desktop.ps1`

### Post-uninstall verify (repo user PowerShell)

```powershell
Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"   # must be False
wsl --shutdown
Start-Sleep -Seconds 8
wsl -d Ubuntu sudo service docker start
wsl -d Ubuntu docker ps
```

### Post-uninstall Docker CLI + Dockge (repo user)

```powershell
cd <repo-or-worker-root>   # see fleet table
git pull --ff-only origin main
. .\deploy\cluster-members\_common\initialize-windows-deploy.ps1
Initialize-AlfaDockerCli    # must print: Docker CLI: WSL (Ubuntu)
```

**`orchestrator` primary only** — start the Dockge UI without touching inference:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-AlfaDockgePrimary.ps1
```

**Workers (`gaming-a` / `gaming-b` / `gaming-c`)** — redeploy after CLI fix:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\<member>\build-start-*.ps1
# or .\run.ps1
```

Re-register the host's agent URL on `orchestrator` primary if the agent shows offline after redeploy.

## Automated agent registration

Dockge's public API is Socket.IO only. `Register-AlfaDockgeAgents` in `deploy/cluster-members/_common/install-dockge-agent.ps1` prints agent URLs to paste into the primary UI.

## Troubleshooting

- **Dockge `bind: port already in use` on Windows** — run `Get-NetTCPConnection -LocalPort <port> -State Listen` and check [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) § Fleet port matrix. **`gaming-a` must use `5003`** (GT3 mobile service owns `5001`).
- **Dockge `invalid volume specification: C:/...` on WSL Docker** — Win10 workers must write `/mnt/c/...` bind paths in `dockge.local.env`. Use `ConvertTo-AlfaDockerHostPath` via `reconcile-dockge-stacks.ps1` (fixed in `_common` deploy scripts 2026-07-14).
- **Compose project name mismatch** — containers started from a directory whose name does not match the Compose project. Re-run the host deploy script (it symlinks and `cd`s into `/opt/stacks/<name>`).
- **`market-pie5-bot` crash-looping** — missing `.env` keys; `apps-105/deploy.sh` skips non-critical stacks with a warning until env is filled.
- **Worker shows no GPU** — check `node_profile.json` under `/var/lib/alfa-ai/` (Linux) or `%ProgramData%\alfa-ai\` (Win). Install NVIDIA Container Toolkit and rerun deploy.

See [INDEX.md](INDEX.md) for the full doc map.
