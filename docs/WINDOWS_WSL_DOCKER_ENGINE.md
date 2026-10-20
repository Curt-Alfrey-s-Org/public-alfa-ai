# Windows — Docker Engine in WSL2 (no Docker Desktop)

Operator guide for **`orchestrator`**, **`gaming-c`**, **`gaming-a`**, **`gaming-b`**: run Petals / Dockge / llama.cpp from **WSL Ubuntu + Docker Engine**, not Docker Desktop.

## Why migrate

| Issue | Docker Desktop | WSL Docker Engine |
|-------|----------------|-------------------|
| `network_mode: host` (Petals `:31330`) | Binds inside Desktop VM — **LAN cannot reach worker ports** | With **mirrored networking**, ports bind on the Windows LAN IP |
| CLI / automation | Desktop GUI + extra VM layer | `wsl docker compose …` — matches Linux workers |
| Disk bloat | ext4.vhdx hard to shrink | Standard WSL ext4 + documented prune cron |
| `gaming-c` broken state | Common after Desktop upgrades | Clean engine install in Ubuntu |

## Migration order (per host)

1. **Verify hub** — images/tarballs on `\\hub\…` or `hub:5000` registry (rebuild after uninstall is OK).
2. **Install WSL engine** — `02-install-docker-wsl-engine.ps1` (Admin PowerShell, repo root).
3. **Smoke test** — `wsl -d Ubuntu docker ps`, `nvidia-smi`, pull/run a GPU container.
4. **Post-startup status** — `run-post-startup-status-with-log.ps1` → SCP log to `inference` hub.
5. **Redeploy stack from WSL** — `deploy.ps1` / `build-start-*.ps1` with docker invoked inside WSL.
6. **Uninstall Desktop** — `99-uninstall-docker-desktop.ps1` only after step 5 is green.

**Start with `orchestrator`** (primary gateway — largest swarm unlock), then **`gaming-a` → `gaming-b` → `gaming-c` → `secondary`**.

## Install (one host)

**Accounts on `orchestrator`:** repo and daily docker work as **`operator`**
(`C:/Users/operator\alfa-ai`). Admin-only install scripts as **`operator`**
(Administrator PowerShell) — **full path to operator repo, no `git pull` in admin session**.

**Step A — `operator`:**

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
```

**Step B — `operator` Administrator:**

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\petals\02-install-docker-wsl-engine.ps1
wsl --shutdown
```

Then smoke test as **`operator`**: `wsl -d Ubuntu docker ps`

```powershell
git pull --ff-only origin main
powershell -ExecutionPolicy Bypass -File .\deploy\petals\02-install-docker-wsl-engine.ps1
wsl --shutdown
```

Re-open Ubuntu, then:

```powershell
wsl -d Ubuntu docker ps
wsl -d Ubuntu nvidia-smi
```

### Mirrored networking (mandatory for Petals)

`02-install-docker-wsl-engine.ps1` appends to `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
swap=0
dnsTunneling=true
firewall=true
autoProxy=true
vmIdleTimeout=-1

[experimental]
hostAddressLoopback=true

[general]
instanceIdleTimeout=-1
```

`hostAddressLoopback=true` is required so Windows can reach services via the host
LAN IP (`orchestrator`), not only `127.0.0.1`. Do **not** set `localhostForwarding`
in mirrored mode (WSL ignores it).

`vmIdleTimeout=-1` and `instanceIdleTimeout=-1` keep the WSL VM running when no
interactive `wsl.exe` session is open — otherwise LAN peers (`apps`, `hub`) time
out while local post-startup still passes via `docker exec`.

### `orchestrator` RAM cap (inference gateway)

Uncapped WSL2 defaults to ~**50% of host RAM** (~15 GB on a 31 GB box). With
inference `rpc-server` + desktop apps, Win11 hits **90%+ RAM** and stutters.

**Recommended** in repo-owner `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=8GB
```

`8 GB` is enough for `dockerd` + one `llamacpp-rpc-server` CPU footprint; leaves
~23 GB for Win11. Tune with:

```powershell
.\deploy\cluster-members\orchestrator\configure-wsl-resources.ps1
.\deploy\cluster-members\orchestrator\configure-wsl-resources.ps1 -WslMemoryGB 6
```

Then **`wsl --shutdown`**.

### `orchestrator` VRAM — 4096 MiB desktop preflight

The RTX **3060 drives the Win11 desktop** (WDDM). NVIDIA GeForce has **no**
supported "reserve VRAM for Windows" driver toggle
([nvidia-smi](https://docs.nvidia.com/deploy/nvidia-smi/)).
`preflight-gpu-empty.sh` fails start if **already used** VRAM is above `MAX_MIB`.

Measured **2026-09-03:** cluster start failed at **2964 MiB** used vs `MAX_MIB=2048`
(Cursor, Chrome, Steam overlay, LibreOffice, `ollama.exe` -- no `llamacpp-rpc`).

| Mechanism | Value |
|-----------|--------|
| `inference-shards.env` `orchestrator` line | **10 GB** tensor split on 12 GB card |
| `deploy-grev27-pool-shard.ps1` | `preflight-gpu-empty.sh` **`MAX_MIB=4096`** |
| Operator habit | Close games / Steam overlay; optional browser HW accel off |

After changing `inference-shards.env`, redeploy the **`inference` coordinator** so
`TENSOR_SPLIT` regenerates (`13,6,10` not `13,6,10.8`).

### Windows Firewall (host + Hyper-V)

With `firewall=true`, mirrored WSL uses **Hyper-V firewall** for inbound LAN
traffic. Host `New-NetFirewallRule` alone is not enough for remote peers.
Microsoft documents Hyper-V rules for mirrored mode:
[WSL mirrored mode networking](https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking).

**Administrator PowerShell (once per Windows worker/gateway host):**

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\_common\install-wsl-lan-firewall.ps1 -Profile operator-93
```

Profiles: `operator-93`, `gaming-worker-a-219`, `gaming-worker-b-249`, `gaming-worker-c-59`. The script
opens the full LAN port set for that host (including inference **`:31350`** on
`orchestrator`) via idempotent host + `New-NetFirewallHyperVRule` entries.

`02-install-docker-wsl-engine.ps1` runs the same install automatically when
`-HostProfile operator-93` is set (default when repo path is under
`C:/Users/operator\`).

Verify from `apps` or `inference`:

```bash
nc -zv orchestrator 31350
```

Do **not** curl `orchestrator:8413` — that was the retired Petals gateway. LiteLLM is
`hub:8413`.

**inference RPC on `orchestrator`:** with mirrored networking, deploy uses `network_mode: host`
-- do **not** apply `docker-compose.rpc-server.wsl-93.yml`
(bridge+ports is Win10 NAT only). Hyper-V firewall rules above are still required.

After any `.wslconfig` change: **`wsl --shutdown`**, then retry.

## Win10 NAT portproxy (gaming-worker-a `gaming-a` — audited deviation)

**When:** Windows 10 (build &lt; 22621) — mirrored mode is unavailable; WSL uses NAT.

**Why:** Petals `network_mode: host` binds `:31330` inside the WSL VM. Remote peers
(`apps`, `orchestrator`, `hub`) dial `orchestrator` on the **Windows LAN IP**. Microsoft’s
documented Win10 path is **`netsh interface portproxy`** from Windows → WSL IP.

**Scripts:**

- `deploy/cluster-members/_common/install-wsl-nat-portproxy.ps1`
- `deploy/cluster-members/_common/run-wsl-nat-portproxy.ps1` (scheduled task runner)
- `.wslconfig` template: `wslconfig-petals-win10-nat.example` (no `networkingMode=mirrored`)

**One-time (Administrator):**

```powershell
cd C:\Users\Corey\alfa-ai
git pull --ff-only origin main
copy deploy\cluster-members\_common\wslconfig-petals-win10-nat.example $env:USERPROFILE\.wslconfig -Force
wsl --shutdown
. .\deploy\cluster-members\_common\install-wsl-nat-portproxy.ps1
Install-AlfaWslNatPortProxy -DisplayNamePrefix 'ALFa gaming-worker-a-219' `
  -TcpPorts 31330,31331,5003 -RegisterScheduledTask
```

**After every `wsl --shutdown` or reboot:** portproxy rules go stale (dynamic WSL IP).
The logon scheduled task re-applies them; `build-start-*.ps1` also refreshes after deploy.

**Verify from `apps`:**

```bash
timeout 3 bash -c "echo >/dev/tcp/orchestrator/31330" && echo DHT_OK
curl -fsS --max-time 5 http://orchestrator/health
```

**Upgrade path:** When `gaming-a` moves to Windows 11, remove portproxy scheduled task,
switch to `wslconfig-petals.example` (mirrored), re-run `02-install-docker-wsl-engine.ps1`.

Microsoft: [Accessing WSL from LAN (portproxy)](https://learn.microsoft.com/en-us/windows/wsl/networking#accessing-a-wsl-2-distribution-from-your-local-area-network-lan).

### systemd in WSL

`install-docker-engine-in-wsl.sh` sets `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Required for `systemctl enable docker` and weekly prune cron.

## Hub unreachable — operator prompt (all Windows hosts)

Deploy scripts dot-source `deploy/cluster-members/_common/hub-fallback-prompt.ps1`
(via `initialize-windows-deploy.ps1`). When a hub SMB hub path is
unreachable, the operator is prompted:

```text
Proceed without hub? [y/N]
```

Default **N** (Enter) **stops** the deploy. Type **y** only to allow the documented
fallback (PyPI, `docker build`, per-host HF volume, etc.) for that context only.

Non-interactive:

```powershell
$env:ALFA_HUB_FALLBACK = 'stop'     # abort without prompt
$env:ALFA_HUB_FALLBACK = 'proceed'   # allow fallbacks without prompt
```

Applies to: `deploy.ps1` / `run.ps1` on `orchestrator`, `gaming-a`, `gaming-b`, `gaming-c`, `secondary`;
`deploy-petals-gateway.ps1`; `deploy-llamacpp-rpc.ps1`; wheel/tarball sync helpers.

## Daily docker commands

From PowerShell (optional profile alias):

```powershell
function docker { wsl -d Ubuntu docker @args }
function docker-compose { wsl -d Ubuntu docker compose @args }
```

Deploy scripts route docker through WSL via `initialize-windows-deploy.ps1`.

## Port preflight (before deploy)

LiteLLM **`:8413`** is on **`hub`**, not `orchestrator`. Do not publish a Petals
gateway or a second LiteLLM on `orchestrator:8413`. Port `8013` on the Windows loopback
may still be IDE port forwarding — leave it alone. Authoritative map:
[PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md).

```powershell
. .\deploy\cluster-members\_common\Test-AlfaWindowsDeployPortPreflight.ps1
Test-AlfaWindowsDeployPortPreflight -Profile operator-93
```

## Post-startup status + logs to `inference` hub

After bringing stacks up:

```powershell
# orchestrator example
powershell -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\run-post-startup-status-with-log.ps1

# gaming-c example (repo at C:\alfa-ai-worker)
powershell -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\run-post-startup-status-with-log.ps1
```

Logs land on `inference` at:

`/home/operator/alfa-ai/logs/cluster-status/post-startup-<profile>-<host>-<timestamp>.log`

Agent analysis on `inference`:

```bash
grep -E 'FAIL|WARN|RESULT' /home/operator/alfa-ai/logs/cluster-status/*.log | tail -50
```

See also [LOG_CAPTURE_RUNBOOK.md](../deploy/cluster-members/LOG_CAPTURE_RUNBOOK.md).

## Uninstall Docker Desktop

**Only after WSL stack is healthy.**

**Option A — GUI (preferred when already in Apps & Features):**

Settings → Apps → Docker Desktop → Uninstall. Then from Admin PowerShell:

```powershell
wsl --shutdown
wsl --unregister docker-desktop
wsl --unregister docker-desktop-data
```

(Only run `--unregister` if those distros still exist after the GUI uninstall.)

**Option B — script (Admin PowerShell):**

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\petals\99-uninstall-docker-desktop.ps1
```

**Accounts on `orchestrator`:** repo and daily docker work as **`operator`**
(`C:/Users/operator\alfa-ai`). Admin tasks (WSL install, GUI uninstall) as
**`operator`** or elevated **`operator`** — always `cd` to the **operator** repo path.

## Orchestrator WSL recovery (`orchestrator` start/stop)

Cluster start runs `preflight-docker-engine.sh` inside Ubuntu via `wsl.exe`. If the
WSL VM is wedged, the call can fail in **0s** with exit **-1** and
`Wsl/Service/E_UNEXPECTED` (no bash output). That is **not** "containers failed to
stop"; port preflight may already have passed.

**Automatic (repo):** `deploy/cluster-members/_common/Invoke-AlfaWslBash.ps1` is
dot-sourced by `Invoke-AlfaAiCluster.ps1` and by `wsl-docker.ps1` before engine
checks. It probes `wsl -d Ubuntu echo`, runs up to **two** `wsl --shutdown` cycles
(10s wait), then retries the bash script once. Official first-step recovery:
[WSL troubleshooting](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting).

**Operator if auto-recovery still fails:**

1. Confirm **C:** free space and `.wslconfig` (`vmIdleTimeout=-1`, `swap=0` when
   disk-tight) per [windows-win11-cluster-operator.mdc](../.cursor/rules/windows-win11-cluster-operator.mdc).
2. **Administrator** PowerShell: `Restart-Service LxssManager` (then `wsl -d Ubuntu echo OK`).
3. Compact or move Ubuntu `ext4.vhdx` only when disk is full — see
   [WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md](WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md).

## Anti-bloat (WSL)

Configured by `install-docker-engine-in-wsl.sh`:

- `/etc/docker/daemon.json` — `log-driver` json-file, `max-size` 50m, `max-file` 3
- `/etc/cron.d/alfa-docker-cleanup` — staggered Sunday schedule via
  `install-docker-cleanup-cron.sh` / `Install-AlfaDockerCleanup.ps1`
  (builder + system prune; see [operations/DOCKER_HOST_CLEANUP.md](operations/DOCKER_HOST_CLEANUP.md)).
  Legacy `/etc/cron.d/docker-cleanup` is removed on install.
- Registry mirror → `http://hub`

**Orphaned Desktop VHD (reclaim after migration):** uninstalling Docker Desktop
leaves `…\AppData\Local\Docker\wsl\disk\docker_data.vhdx` behind (no
`docker-desktop*` distro mounts it post-migration). On `orchestrator` this was **294 GB**
of dead weight and, with C: full, caused WSL `getpwnam … failed (EIO)`. Confirm
no `docker-desktop*` distro in `wsl -l -v`, then delete the file. The live WSL
engine disk is the **`Ubuntu`** distro's `ext4.vhdx` (under its registry
`BasePath`, e.g. `C:/Users/operator\WSL\Ubuntu\`) — never delete that. After large
deletions, `wsl --shutdown` then compact `ext4.vhdx` (`Optimize-VHD` / `diskpart`).

## Related

- [operations/STORAGE_CLEANUP_AND_BUILD_OFFLOAD.md](operations/STORAGE_CLEANUP_AND_BUILD_OFFLOAD.md) — keep workers lean: orphaned-VHD cleanup, build offload to `hub`, SSD priority
- [WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md](WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md) — Desktop VHD compact (legacy)
- [petals/WORKER_ROLLOUT.md](petals/WORKER_ROLLOUT.md) — swarm bring-up after engine migration
- [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) — Petals / RPC ports per host
