# GPU overclock and power tuning with LACT (Linux inference hosts)

**Scope:** Linux GPU hosts that run inference `rpc-server` shards. **In scope for LACT
headless:** **`inference`** (dual NVIDIA) and **`pool-opt-in`** (GTX 1660 Super). **Out of scope:**
**`orchestrator`** (Windows Afterburner), **`apps`** (CPU-only, no `nvidia-smi`), **`hub`**
hub (do not `apt install` LACT on SCALE).

**LACT is not a web UI.** There is no HTTP endpoint and no browser page. Remote
control uses a **TCP socket on port 12853** consumed by the **GTK desktop app**
(`lact gui --tcp-address HOST:12853`), not curl or nginx.

## Single source: alfa-ai repo vs upstream LACT

| Piece | Where it lives |
|-------|----------------|
| **LACT application** (daemon + GUI binaries) | Upstream only: [ilya-zlobintsev/LACT](https://github.com/ilya-zlobintsev/LACT) — **not** vendored or forked into alfa-ai |
| **Cluster install, presets, operator doc** | **This repo** (`alfa-ai`) — every host pulls the same scripts/config via `git pull` |
| **Linux GPU hosts** (`inference`, `pool-opt-in`) | `sudo bash deploy/cluster-members/_common/install-lact-headless.sh` after pull |
| **Windows operator** (`orchestrator`) | WSL GUI client + desktop shortcuts from `deploy/cluster-members/orchestrator/` |

Do **not** copy one-off `install-lact*.sh` or `/etc/lact/config.yaml` between hosts by hand.
Edit templates under `deploy/cluster-members/_common/lact/`, commit/push from the owning
clone, pull on consumers, re-run the install script (or merge into live config and
`systemctl restart lactd`).

Official references:

- LACT project: https://github.com/ilya-zlobintsev/LACT
- Config file (`/etc/lact/config.yaml`): https://github.com/ilya-zlobintsev/LACT/blob/master/docs/CONFIG.md
- Hardware support (NVIDIA clock offsets need driver **555+**, **565+ recommended**): https://github.com/ilya-zlobintsev/LACT/wiki/Hardware-Support
- Remote management (TCP has **no auth or encryption**): https://github.com/ilya-zlobintsev/LACT#remote-management
- Release **v0.10.1** headless `.deb` (~2.9 MB, hub policy OK): https://github.com/ilya-zlobintsev/LACT/releases/tag/v0.10.1 file `lact-headless-0.10.1-0.amd64.ubuntu-2604.deb`
- `nvidia-smi` power and clock limits: https://docs.nvidia.com/deploy/nvidia-smi/index.html
- NVIDIA Coolbits (unsupported clock offsets class): https://download.nvidia.com/XFree86/Linux-x86_64/580.82.07/README/xconfigoptions.html
- hub NVIDIA drivers (`hub` only; no LACT package): https://apps.hub.com/getting-started/initial-setup/#installing-nvidia-drivers

## Fleet map

| Host | IP | GPU | LACT | Remote TCP | Notes |
|------|-----|-----|------|------------|-------|
| **`inference`** ai-148 | `orchestrator` | RTX 5060 8 GB + RTX 3060 12 GB | **Yes** (planned) | **`orchestrator`** | Core inference shards `:31356` / `:31357` |
| **`pool-opt-in`** ALFA-AI | `orchestrator` | GTX 1660 Super 6 GB | **Yes** (planned) | **`orchestrator`** | inference opt-in shard `:31354` only (not RAG) |
| **`apps`** apps | `apps` | none | **No** | -- | CPU-only; `nvidia-smi` missing |
| **`hub`** brain | `hub` | RTX 3050 6 GB | **No apt on SCALE** | -- | Driver **550.142** too old for LACT offsets; use `nvidia-smi` only |
| **`orchestrator`** orchestrator | `orchestrator` | RTX 3060 (Windows) | **No** | -- | Operator uses Afterburner **+200 / +400** |

Port matrix row: [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) (LACT TCP **12853**).

## Live baseline (2026-09-20, `nvidia-smi`)

Captured with inference **stopped** (no `rpc-server` container). Persistence mode **off** on
all GPUs below.

### `inference` (Ubuntu 26.04, driver **595.84**)

| GPU | PCI bus | Model | Power draw / limit | Max clocks (SM / mem) |
|-----|---------|-------|--------------------|------------------------|
| GPU0 | `0000:01:00.0` | RTX 5060 8 GB | 145 W / 160 W max | 3090 / 14001 MHz |
| GPU1 | `0000:02:00.0` | RTX 3060 12 GB | 170 W / 170 W | 2130 / 7501 MHz |

### `pool-opt-in` (Ubuntu 26.04, driver **595.84**)

| GPU | PCI bus | Model | Power draw / limit | Max clocks (SM / mem) |
|-----|---------|-------|--------------------|------------------------|
| GPU0 | `0000:01:00.0` | GTX 1660 Super 6 GB | 125 W / 150 W max | 2145 / 7001 MHz |

### `apps`

No NVIDIA GPU; `nvidia-smi` not installed.

### `hub` (inventory; operator-maintained)

RTX 3050 6 GB, driver **550.142** per [NODE_INVENTORY.md](NODE_INVENTORY.md). Below LACT
NVIDIA offset minimum (**555+**). Use **`nvidia-smi --power-limit`** and
**`--lock-gpu-clocks`** only until driver upgrade is planned on SCALE.

## NVIDIA reference TGP (vendor pages)

Use these as sanity checks for `power_cap` presets (not hard caps in LACT):

| GPU | Reference TGP | Source |
|-----|---------------|--------|
| RTX 3050 6 GB | 70 W | https://www.nvidia.com/en-us/geforce/graphics-cards/30-series/rtx-3050/ |
| GTX 1660 Super | 125 W | (factory board; live `pool-opt-in` limit 150 W) |
| RTX 3060 | 170 W | (live `inference` at board max 170 W) |
| RTX 5060 | 145 W | https://www.nvidia.com/en-us/geforce/graphics-cards/50-series/rtx-5060-family/ |

## ALFa AI presets (config only; no VF curve)

**Do not use** `gpu_vf_curve`, `nvidia_gpu_vf_curve`, or `voltage_boost` in LACT config
for inference hosts. Use **`gpu_clock_offsets`**, **`mem_clock_offsets`**, and **`power_cap`**
per [CONFIG.md](https://github.com/ilya-zlobintsev/LACT/blob/master/docs/CONFIG.md).

Example shape (GPU IDs from `lact cli list-gpus` after install):

```yaml
gpus:
  <GPU_ID_FROM_list-gpus>:
    gpu_clock_offsets:
      0: 150
    mem_clock_offsets:
      0: 400
    power_cap: 170.0
```

| Host | GPU | gpu_clock_offsets pstate 0 | mem_clock_offsets | power_cap (W) |
|------|-----|----------------------------|-------------------|---------------|
| **`pool-opt-in`** | 1660 Super | **+100** | **+400** | **140** |
| **`inference`** | RTX 3060 | **+197** | **+574** | **170** (match `orchestrator` Afterburner) |
| **`inference`** | RTX 5060 | **+150** | **+400** | **155** |
| **`hub`** | RTX 3050 | **+75** / **+300** mem | only if LACT offsets work after driver upgrade | else **`nvidia-smi`** (operator, later) |

NVIDIA clock offsets are **Coolbits-class unsupported features** per NVIDIA docs. Treat
stability as experimental; revert on rpc-server crash or ECC-like errors in `dmesg`.

## Fan control (Thermals tab in LACT GUI)

LACT supports **custom fan curves on NVIDIA** via NVML
([CONFIG.md](https://github.com/ilya-zlobintsev/LACT/blob/master/docs/CONFIG.md)).
Tune in the remote GUI **Thermals** tab; curves are stored in **`/etc/lact/config.yaml`**
on each host (operator-owned -- not synced from git).

One-time enable (new hosts only; **do not re-run** after you customize curves in the GUI):

```bash
sudo bash deploy/cluster-members/_common/enable-lact-fan-control.sh
```

Reference fragment: `deploy/cluster-members/_common/lact/fan-control-nvidia-ai.yaml.fragment`.

## Crash capture during cluster start/stop

`Start-Stop-AlfaAi.ps1` STEP 0 starts inference **error-only** recorders (docker, kernel Xid/NVRM,
`lactd`, throttle baseline). Logs:
`C:/Users/operator\alfa-ai\logs\inference-sessions\<session>-start\inference-<host>-errors.log`.

OC red flags: `Xid`, `NVRM`, `CUDA`, `RPC server crashed`, `illegal memory`, `throttle`.
Full stop, lower VRAM offset, full start if OC is suspect.

## Daemon, persistence, and TCP remote

1. **Service:** `lactd` via systemd (`systemctl enable --now lactd`). Settings reload on
   config file change; daemon keys like `tcp_listen_address` need
   `systemctl restart lactd`.
2. **Config path:** `/etc/lact/config.yaml`
3. **Remote TCP (optional):** set **`tcp_listen_address`** to the host **LAN IP**, not
   `0.0.0.0`:

```yaml
daemon:
  tcp_listen_address: orchestrator
  log_level: info
```

Repeat on `pool-opt-in` with `orchestrator`.

4. **Firewall:** bind is the host LAN IP (not `0.0.0.0`). The installer adds a UFW
   allow from **`orchestrator/24`** to TCP **12853** only when UFW is already active.
   It does not enable UFW. Optional extra deny for other sources:

```bash
sudo ufw allow from orchestrator/24 to any port 12853 proto tcp comment 'LACT LAN only'
sudo ufw reload
```

5. **Remote GUI (GTK, not browser):** on an operator workstation with LACT GUI installed:

```bash
lact gui --tcp-address orchestrator
```

Per LACT README: TCP has **no authentication or encryption**. Use only on trusted LAN;
never expose **12853** to the internet.

## inference safety (mandatory)

- Apply or change GPU OC **with inference stopped** when possible
  ([CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md): full orchestrator
  stop/start from `orchestrator` only).
- **Memory OC** can crash **`rpc-server`** and wedge the pool. Do **not** piecemeal restart
  individual shards or the coordinator
  ([no-piecemeal-cluster-scripts.mdc](../.cursor/rules/no-piecemeal-cluster-scripts.mdc)).
- After bad OC: stop cluster, reset clocks (`nvidia-smi -rgc` / `-rmc` or LACT defaults),
  then one full start cycle.
- LACT recovery wiki: https://github.com/ilya-zlobintsev/LACT/wiki/Recovering-from-a-bad-overclock

## `hub` hub (no LACT package)

Do **not** install LACT on hub SCALE via apt. The hub brain uses Apps-managed NVIDIA
drivers ([hub NVIDIA setup](https://apps.hub.com/getting-started/initial-setup/#installing-nvidia-drivers)).
With driver **550.142**, use **`nvidia-smi --power-limit`** and **`--lock-gpu-clocks`**
inside the shard container host namespace or operator shell as documented in
[GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md). LACT offset presets for the 3050
(**+75 / +300**) are deferred until an operator upgrades the `hub` driver to **565+**.

## `orchestrator` Windows (no headless daemon; GUI client from repo)

The Windows **3060** is tuned with **MSI Afterburner** (operator-owned; not managed by
`lactd`). **Do not** run `install-lact-headless.sh` on `orchestrator`.

Use the **remote LACT GTK client** from this repo to view/adjust **`inference`** and **`pool-opt-in`**
GPUs over TCP:

1. One-time WSL GUI package (Ubuntu 26.04 WSL on `orchestrator`):

```powershell
wsl -d Ubuntu bash -lc "curl -fsSL -o /tmp/lact-gui.deb https://github.com/ilya-zlobintsev/LACT/releases/download/v0.10.1/lact-0.10.1-0.amd64.ubuntu-2604.deb && sudo dpkg -i /tmp/lact-gui.deb && sudo apt-get install -y -f && sudo systemctl disable --now lactd"
```

Use Linux `curl` and `dpkg -i` (not `apt-get install /path/file.deb`).

2. Desktop shortcuts (after `git pull`):

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Install-LactDesktopShortcuts.ps1
```

Scripts: `deploy/cluster-members/orchestrator/Launch-LactGui.ps1`,
`Install-LactDesktopShortcuts.ps1`, `lact-icon.png`.

## Install

After `git pull` on the target host (**inference** or **pool-opt-in** only):

```bash
cd ~/alfa-ai
git pull --ff-only origin main
sudo bash deploy/cluster-members/_common/install-lact-headless.sh
```

Script: `deploy/cluster-members/_common/install-lact-headless.sh`  
Config templates: `deploy/cluster-members/_common/lact/configinference.yaml.example`,
`deploy/cluster-members/_common/lact/configpool-opt-in.yaml.example`

The script downloads **`lact-headless-0.10.1-0.amd64.ubuntu-2604.deb`** from
[v0.10.1 release](https://github.com/ilya-zlobintsev/LACT/releases/tag/v0.10.1) (~2.9 MB,
under hub 100 MB policy; seed on `hub` before air-gapped workers if needed), installs via
`dpkg`, copies the host example to `/etc/lact/config.yaml`, enables `lactd`, remaps GPU IDs
from `lact cli list-gpus` when PCI differs, binds TCP **12853** to the host LAN IP, and
optionally opens UFW when active.

Post-install checks:

```bash
systemctl is-active lactd
lact cli list-gpus
nvidia-smi
```

## Related

- [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) -- TCP **12853** on `inference` / `pool-opt-in`
- [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) -- inference topology
- [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) -- stop before OC
- [NODE_INVENTORY.md](NODE_INVENTORY.md) -- hardware inventory
- [deploy/cluster-members/inference-coordinator/README.md](../deploy/cluster-members/inference-coordinator/README.md)
- [DOCKGE_100_OPERATOR.md](DOCKGE_100_OPERATOR.md)
- [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md) -- CPU-only, no LACT
