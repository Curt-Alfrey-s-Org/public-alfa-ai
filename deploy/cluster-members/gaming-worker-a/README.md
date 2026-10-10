# gaming-worker-a (`gaming-a`) — Dockge worker + optional RPC (Petals retired)

Win10/WSL host **`orchestrator`**: RTX 5060 8 GB (Blackwell). **Petals/Hivemind
retired 2026-07-09** — do not bring up `petals-worker`. Role today: Dockge agent
(`:5003`) + optional RPC shard when the operator wants capacity.

| Field | Value |
|-------|--------|
| IP | `orchestrator` |
| Prometheus instance | `gaming-worker-a-219` |
| Windows hostname | `DESKTOP-7EOGC3R` |
| GPU | RTX 5060 8151 MiB (Blackwell, driver 610.74) |
| Dockge agent | **`:5003`** (not 5001 — GT3 mobile service on Win10) |
| Primary path | Dockge + optional inference RPC shard `:31352` |
| Hub SMB | `\\hub\docker-images`, `petals-wheels`, `huggingface` |

## Hardware inventory (live capture 2026-07-14)

Source: `nvidia-smi`, `wmic`, `Get-NetAdapter` on this host. Update after any swap.

| Component | Spec |
|-----------|------|
| OS | Windows 10 Pro 22H2 (build 19045) |
| Board | Gigabyte Z390 GAMING X-CF, BIOS F9 |
| CPU | Intel Core i5-9600K 6c/6t @ 3.70 GHz |
| RAM | 64 GB DDR4 (63.9 GiB reported) |
| GPU | NVIDIA GeForce RTX 5060, 8151 MiB, Blackwell cc 12.0 |
| GPU PCIe | Gen3 x8 (GPU max Gen5 x16; host max Gen3) |
| GPU power | 145 W limit; ~27 W idle |
| GPU UUID | `GPU-1b7f6522-826c-f34c-4b61-9ee3683e786f` |
| Disk C: | Crucial P3 Plus 1 TB NVMe (~165 GiB free) |
| Disk D: | Samsung 870 EVO 500 GB SATA (~142 GiB free) |
| LAN | Intel I219-V 1 GbE, MAC `18-C0-4D-43-56-13` |
| WSL | Ubuntu, Docker Engine 29.5.3 |
| PawnIO | Running (required for OhmGraphite CPU temps) |

SSoT: [FOUR_HOST_FRONTIER_POOL.md](../../../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md) §9.

### Agent SSH from `orchestrator` (required before unattended ops)

One-time OpenSSH + dedicated key so Cursor on `orchestrator` can work like other members:

1. On `orchestrator`: `Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).` (writes `id_ed25519_93_219.pub` here).
2. On `gaming-a` Admin: `enable-agent-ssh-from-93.ps1` after `git pull`.
3. Smoke from `orchestrator`: `ssh -i ...\id_ed25519_93_219 USER@orchestrator hostname`.

Full runbook: [AGENT_SSH_FROM_93.md](AGENT_SSH_FROM_93.md).

### Lessons carried from `orchestrator` (do not regress)

| Lesson | On gaming-worker-a |
|--------|----------------|
| **WSL Docker Engine, not Desktop** | Install via `02-install-docker-wsl-engine.ps1`; route CLI as `wsl -d Ubuntu docker …` |
| **Win10 = NAT + portproxy** | Mirrored WSL needs Win11 build >= 22621; this host stays NAT — use `wslconfig-petals-win10-nat.example` + `install-wsl-nat-portproxy.ps1` for `:5003` (and RPC ports when joining pool) |
| **Hub-first images** | Never `docker pull` public registries for >100 MB; `docker load` from `\\hub\docker-images\` / `hub:5000` |
| **Disk pressure** | After failed `docker load` / WSL disk errors: clear `<cache-root>\docker-images\*.tar.gz` (see **Windows cache root** below), set `swap=0` in `.wslconfig`, `wsl --shutdown` (same pattern as `orchestrator` Steps C/D) |
| **PS 5.1 only** | Operator paste and `*.ps1` must be ASCII / no `&&` / no ternary ([windows-powershell-51-syntax](../../../.cursor/rules/windows-powershell-51-syntax.mdc)) |
| **Petals retired** | Purge leftover `petals-worker` stacks; do not start Petals/DHT |
| **Opportunistic only** | Four-host pool (`orchestrator`/`apps`/`hub`/`inference`) does not require `gaming-a` online; join RPC only when gaming idle |
| **HTTP smoke** | Use `curl.exe` in paste blocks, not `Invoke-WebRequest` aliases |
| **inference join (2026-07-15)** | Full symptom/fix table: [inference_GAMING_HOST_JOIN.md](../../../docs/inference_GAMING_HOST_JOIN.md) -- `MAX_MIB=3072` + gaming `VRAM_GB=5`, no interactive hub prompt over SSH, LAN probe = this host (not `orchestrator`), cast LAN IP to `[string]`, commit before start (`git reset --hard`) |

### Petals/Hivemind cleanup (done 2026-07-14)

Completed on this host before Dockge + monitoring bring-up:

1. `scripts/purge-petals-runtime-on-host.sh --apply` in WSL against `C:\Users\Corey\alfa-ai`.
2. Stale Win10 portproxy rules for DHT **31330/31331** removed; **`:5003`** refreshed for Dockge.
3. Do **not** run Petals worker bring-up, `deploy-petals-gateway`, or retired `docs/petals/*`.
4. Optional llama.cpp RPC join only when gaming idle ([GAMING_DOCKGE_HANDOFF.md](GAMING_DOCKGE_HANDOFF.md)).

### Windows cache root (docker tarball staging)

gaming-worker-a deploy scripts call `deploy/cluster-members/_common/Get-AlfaWindowsCacheRoot.ps1`
at startup. The picker chooses `*\alfa-ai-cache` on a fixed NTFS drive that is **under 80%
used** with at least **30 GB free**, prefers **non-C:** when eligible, then **G:** when
eligible, else the drive with the most free space. WSL `docker load` uses
`/mnt/<letter>/alfa-ai-cache/docker-images/...`.

Override for testing: set `ALFA_WINDOWS_CACHE_ROOT` (full path, e.g. `D:\alfa-ai-cache`)
before running deploy.

Offline inference prep on this host only:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\Prep-GamingWorkerinferenceReady.ps1 -LoadImage
```

### inference join (`gaming-a` :31352, when gaming idle)

**Prerequisites:** SMB hub map, WSL Docker, SSH from `orchestrator` working.

1. **One-time at the desktop console** (not SSH) -- stores SMB creds for agent/SSH:

```powershell
cd C:\Users\Corey\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\prep-windows-blackwell-worker.ps1 -MemberFolder gaming-worker-a-219 -SmbUser Corey -inferenceOnly
```

Maps **H:** `docker-images`, **Y:** `petals-wheels`, **Z:** `huggingface` via `cmdkey`
+ `/persistent:yes`. After this, `orchestrator` SSH can run `net use H: \\hub\docker-images /persistent:yes` with no password.

Interactive-only fallback (no Credential Manager entry):

```powershell
net use H: \\hub\docker-images /user:Corey * /persistent:yes
```

2. Deploy shard (first time or after hub image update):

```powershell
cd C:\Users\Corey\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\deploy-grev27-pool-shard.ps1
```

3. Cluster cutover: commit/push `inference-shards.env` from `orchestrator`, `git pull` on `hub`,
   then **one** full `Start-Stop-AlfaAi.ps1 stop` + `start` from `orchestrator` (orchestrator
   deploys `gaming-a` automatically when the line is present).

When returning to gaming, comment out the `gaming-a` line in `inference-shards.env`, regenerate
`.env.rpc` on `hub`, and full stop+start without `gaming-a` online.

| Item | Value |
|------|--------|
| RPC port | **`:31352`** (Win10 NAT portproxy + `docker-compose.rpc-server.wsl-93.yml`) |
| Deploy script | `deploy-grev27-pool-shard.ps1` |
| Tensor slice | **8** GB (see `inference-shards.env`) |

### Monitoring (Prometheus on `monitor`)

Install from the **monitoring** repo (`hosts/orchestrator/`). Clone path on this host: `C:\Users\Corey\monitoring`.

| Script | Port | Prometheus job | Metrics |
|--------|------|----------------|---------|
| `install-metrics.ps1` | **9182** | `windows-exporter-remote` | `windows_cpu_*`, `windows_net_*` |
| `install-gpu-metrics.ps1` | **9835** | `nvidia-gpu-exporter-remote` | `nvidia_smi_temperature_gpu` |
| `install-cpu-temps.ps1` | **4445** | `ohmgraphite-remote` | `ohm_cpu_celsius` (needs PawnIO) |
| `install-dozzle-agent.ps1` | **7007** | (Dozzle UI) | container logs |

**Prerequisite:** [PawnIO](https://pawnio.eu/) kernel driver installed and running (verify: `Get-Service PawnIO`).

Allow inbound from **`monitor`** on `:9182`, `:9835`, `:4445`, and `:7007`.

```powershell
cd C:\Users\Corey\monitoring\hosts\orchestrator
.\install-metrics.ps1
.\install-gpu-metrics.ps1
.\install-cpu-temps.ps1
.\install-dozzle-agent.ps1
```

Verify from `monitor`:

```bash
curl -fsS http://orchestrator/metrics | head
curl -fsS http://orchestrator/metrics | grep nvidia_smi_temperature_gpu
curl -fsS http://orchestrator/metrics/ | grep ohm_cpu_celsius
```

Grafana **Homelab temperatures** dashboard picks up GPU (`nvidia_smi_temperature_gpu`) and CPU (`ohm_cpu_celsius`) automatically when scrapes are up.

### Efficiency + gaming handoff

One-time tuning (Admin PowerShell):

```powershell
cd C:\Users\Corey\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\apply-gaming-worker-a-efficiency.ps1
```

Sets WSL `memory=12GB`, removes Ollama startup, Defender exclusions. **GPU fans:** set GPU Tweak III Manual 100% and save at startup (no CLI).

| Script | When |
|--------|------|
| `gaming-stop-for-session.ps1 -ShutdownWsl` | Before gaming (stops pool shard, frees GPU/RAM) |
| `gaming-resume-pool-shard.ps1` | After gaming (start WSL only; shard at next cluster Start) |
| `gaming-desktop-menu.ps1` | Small GUI with both actions |
| `install-gaming-desktop-shortcut.ps1` | One-time: puts **ALFa Gaming Mode** icon on Desktop |

Desktop icon (run once):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\install-gaming-desktop-shortcut.ps1
```

See [GAMING_DOCKGE_HANDOFF.md](GAMING_DOCKGE_HANDOFF.md).

---

## Storage hygiene + build from `hub` (fleet policy)

This host is a **pure consumer** — build the **`cuda-blackwell`** image on
**`hub`** once, then `docker load` the tarball here; **never build locally**.
Same policy on every host. Canonical steps:
[WINDOWS_WSL_ROLLOUT_CHECKLIST.md](../../../docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md)
Phase H · runbook
[operations/STORAGE_CLEANUP_AND_BUILD_OFFLOAD.md](../../../docs/operations/STORAGE_CLEANUP_AND_BUILD_OFFLOAD.md).

- **Variant → tarball:** `cuda-blackwell` → `alfa-petals-worker-gpu-12.8.0-cuda-blackwell.tar.gz`
- **Build on `hub`:** `sudo bash scripts/build-worker-image-on-hub.sh cuda-blackwell`
- **After Docker Desktop uninstall:** delete the orphaned
  `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx` (never the Ubuntu `ext4.vhdx`).
  On Win10/`gaming-a` the path is `C:\Users\<user>\AppData\Local\Docker\wsl\disk\`.
- **After a healthy no-build deploy:** `docker image rm alfa-petals-ml-base:*`,
  `docker builder prune -af`, clear `build-contexts/wheels-*` (keep `.gitkeep`).

---

## Before you start (once per cluster, on `orchestrator`)

Someone with the primary repo on `orchestrator` must publish this folder to SMB:

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stage-cluster-members.ps1
```

That copies `deploy\cluster-members\*` and `_common\repo\` to `\\hub\temp\cluster_members\`.

Alternative on **`hub`** (hub, requires sudo on hub dataset):

```bash
setopt interactivecomments
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
git pull --ff-only origin main
sudo bash scripts/stage-cluster-members.sh
```

---

## One-time on gaming-worker-a

### 1. hub SMB user on `hub` (operator)

`operator` is SSH-only. Create a **local SMB user** for this PC (e.g. `Corey`) and grant **Read** ACL on `petals-wheels`, `huggingface`, `docker-images`. See [gaming-worker-c-59/README.md](../gaming-worker-c-59/README.md) § hub SMB user for the `midclt` pattern.

### 2. Prerequisites (Win10 — NAT + portproxy)

**This host stays on Windows 10** until upgrade — mirrored WSL is **not available**
(build &lt; 22621). Use Microsoft's [netsh portproxy](https://learn.microsoft.com/en-us/windows/wsl/networking#accessing-a-wsl-2-distribution-from-your-local-area-network-lan)
path documented in [WINDOWS_WSL_DOCKER_ENGINE.md](../../../docs/WINDOWS_WSL_DOCKER_ENGINE.md)
§ Win10 NAT portproxy.

**Docker:** WSL Docker Engine in Ubuntu — **not** Docker Desktop.

| Item | gaming-worker-a (`gaming-a` Win10) |
|------|---------------------------|
| `.wslconfig` | Copy [`wslconfig-petals-win10-nat.example`](../_common/wslconfig-petals-win10-nat.example) → `C:\Users\<YOU>\.wslconfig` (**not** the Win11 mirrored example) |
| LAN ports | **`31330`, `31331`, `5003`, `31352`** (inference) — `install-wsl-nat-portproxy.ps1` |
| Portproxy refresh | Scheduled task at logon + after every `build-start` (WSL IP is dynamic) |
| Post-startup | `run-post-startup-status-with-log.ps1 -HostProfile gaming-worker-a-219 -WarmUpSec 180` → **`RESULT: OK`** |
| Remote verify | From `apps`: `timeout 3 bash -c "echo >/dev/tcp/orchestrator/31330"` |

**Phase B — Admin (once):**

```powershell
cd C:\Users\YOURUSER\alfa-ai
git pull --ff-only origin main
wsl --install -d Ubuntu
powershell -ExecutionPolicy Bypass -File .\deploy\petals\02-install-docker-wsl-engine.ps1 `
  -NatPortProxyPorts 31330,31331,5003 -RegisterNatPortProxyTask
copy .\deploy\cluster-members\_common\wslconfig-petals-win10-nat.example $env:USERPROFILE\.wslconfig -Force
wsl --shutdown
```

If Docker was already installed, refresh portproxy only:

```powershell
. .\deploy\cluster-members\_common\install-wsl-nat-portproxy.ps1
Install-AlfaWslNatPortProxy -DisplayNamePrefix 'ALFa gaming-worker-a-219' `
  -TcpPorts 31330,31331,5003 -RegisterScheduledTask
```

Also required:

- `wsl -d Ubuntu nvidia-smi` and `wsl -d Ubuntu docker ps` succeed.
- `apps` UFW allows `31330/tcp` from `orchestrator` (configured May 2026).
- **`apps` bootstrap** `petals-worker` must be **Up** (404 on bootstrap API = restart on `apps`).
- Windows clock within **3 seconds** of `apps`/`hub` (hivemind DHT).

### 3. Git checkout (recommended)

```powershell
git clone https://github.com/example/alfa-ai.git C:\Users\YOURUSER\alfa-ai
cd C:\Users\YOURUSER\alfa-ai
git pull --ff-only origin main
```

### 4. Prep (normal user — not Admin)

Use **Notepad** to copy commands (Discord/chat strips `\\`):

```powershell
cd C:\Users\YOURUSER\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\_common\prep-windows-blackwell-worker.ps1 `
  -MemberFolder gaming-worker-a-219 -SmbUser Corey
```

Maps **`Y:`/`Z:`** via `hub`, copies `.env.worker`, strips CRLF, probes bootstrap auth.

### 5. Secrets — edit both files

```powershell
notepad C:\Users\YOURUSER\alfa-ai\deploy\cluster-members\gaming-worker-a\.env.worker
notepad C:\Users\YOURUSER\alfa-ai\deploy\petals\.env.worker
```

Set at minimum:

| Key | Value |
|-----|--------|
| `ALFA_WORKER_HEARTBEAT_TOKEN` | **Exact** `ALFA_WORKER_HEARTBEAT_TOKEN` from `hub` `deploy/.env` (64 chars — **not** the short `ALFA_AI_API_TOKEN`) |
| `HF_TOKEN` | Hugging Face token (gated Llama-3.3) |
| `ALFA_BRAIN_URL` | `http://hub` (default in example) |
| `PETALS_INITIAL_PEERS` | Leave **empty** (entrypoint resolves bootstrap from brain) |

Re-run prep if bootstrap probe returned **403**.

Optional **Admin once**: `hub hub` in hosts file.

---

## Deploy (every time)

**Recommended — one command (deploy + portproxy + post-startup gate):**

```powershell
cd C:\Users\YOURUSER\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File `
    .\deploy\cluster-members\gaming-worker-a\startup-gaming-worker-a-219.ps1
```

**Deploy only** (skip post-startup gate):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
    .\deploy\cluster-members\gaming-worker-a\build-start-gaming-worker-a-219.ps1
```

**Normal user** (build-start opens firewall when run as Admin; portproxy uses scheduled task otherwise):

```powershell
cd C:\Users\YOURUSER\alfa-ai
git pull --ff-only origin main
powershell -NoProfile -ExecutionPolicy Bypass -File `
    .\deploy\cluster-members\gaming-worker-a\build-start-gaming-worker-a-219.ps1
```

**No local git clone?** Run from SMB after `orchestrator` staged:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
    \\hub\temp\cluster_members\gaming-worker-a-219\build-start-gaming-worker-a-219.ps1
```

First run builds `alfa-petals-ml-base:cuda-blackwell` offline from SMB wheels (**10–30 min**). Later runs are incremental.

Optional flags: `-SkipPull`, `-SkipFirewall`, `-SkipMirror`, `-SkipSmoke`, `-SkipLogUpload`.

---

## Logs (automatic — remote building)

**Do not paste long logs into chat.** `build-start-*.ps1` always:

1. Writes a full PowerShell transcript locally:
   `deploy\cluster-members\gaming-worker-a\logs\build-start-<UTC>.log`
2. Dumps all Petals/Docker container logs via `scripts\collect-alfa-docker-logs-to-148.ps1`
3. **SCP's both files to `inference` hub:**

   `operator@orchestrator:/home/operator/alfa-ai/logs/cluster-docker/`

Requires **Git for Windows** (`bash.exe` — not the WSL stub) and **SSH key auth** to `operator@orchestrator`. The script prints the remote path when upload succeeds; analysis happens on `inference`.

To keep logs local only (offline / no SSH):

```powershell
...\build-start-gaming-worker-a-219.ps1 -SkipLogUpload
```

Manual re-upload after a failed SCP:

```powershell
cd C:\Users\YOURUSER\alfa-ai
.\scripts\collect-alfa-docker-logs-to-148.ps1
scp .\deploy\cluster-members\gaming-worker-a\logs\build-start-*.log `
    operator@orchestrator:/home/operator/alfa-ai/logs/cluster-docker/
```

---

## Verify (current path)

**Post-startup gate (Dockge / WSL Docker):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\_common\run-post-startup-status-with-log.ps1 `
  -HostProfile gaming-worker-a-219 -WarmUpSec 180
```

Require **`RESULT: OK`**. Log on `inference` hub: `logs/cluster-status/`.

**Docker Engine:**

```powershell
wsl -d Ubuntu docker ps
wsl -d Ubuntu nvidia-smi
```

**Dockge agent (LAN):** from `orchestrator` after portproxy is healthy:

```powershell
curl.exe -fsS --max-time 10 http://orchestrator/
```

**Optional RPC shard:** only when the operator joins inference capacity and the
orchestrator path allows it -- never piecemeal-restart shards while the
coordinator is up. See [LLAMACPP_RPC_OPERATOR.md](../../../docs/LLAMACPP_RPC_OPERATOR.md)
and [GAMING_DOCKGE_HANDOFF.md](GAMING_DOCKGE_HANDOFF.md).

Uninstall Docker Desktop (Admin) only after WSL Engine + post-startup are green.

> **Historical:** Petals `:31330`/`:31331` verify steps are retired. Do not bring
> up `petals-worker`.

---

## Next host

When gaming-worker-a SSH + Dockge path is green, optional next gaming host is
**gaming-worker-b `gaming-b`**: [../gaming-worker-b-249/README.md](../gaming-worker-b-249/README.md).
