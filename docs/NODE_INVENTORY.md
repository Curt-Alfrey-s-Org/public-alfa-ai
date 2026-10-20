# Cluster node inventory

Operator-maintained list of machines that participate in the ALFa AI stack
(inference llama.cpp RPC, brain, RAG, storage). **Update this file** when you add or
retire a node, or when hardware changes.

> **RETIRED (do not treat as live):** Petals / Hivemind, Llama-3.3-70B, Qwen 35B MoE
> (`qwen3.6:35b-a3b` / speed-tier). Production chat = **Qwen3.6-27B** RPC pool
> (`frontier-code` / `frontier`). See [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md),
> [DOCUMENTATION_CANONICAL.md](DOCUMENTATION_CANONICAL.md). Historical Petals docs:
> [history/](history/).

**Roadmap:** [ROADMAP.md](ROADMAP.md) — inference frontier-code, four-host core +
inference opt-in `gaming-a` / `gaming-c` / `gaming-b` / `secondary` / `pool-opt-in` (never required for core green; train lock blocks `gaming-c`/`gaming-b`).

**Admin Health hosts:** [ADMIN_HEALTH_WEB_WORKFLOW.md](ADMIN_HEALTH_WEB_WORKFLOW.md)
(Infrastructure Hosts cards: `hub` / `inference` / `orchestrator` / `gaming-b` / `gaming-c` / `gaming-a` /
`secondary` / `pool-opt-in` / `apps`).

**Per-host readiness / sanity (verified status):** [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md).

**Brain migration (April 2026):** [history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md).

**VM100:** inference RPC shard **`:31354` only**. **RAG** is CPU on **`rag`**. **Brain + DB stay on `hub`**. [DOCKGE_100_OPERATOR.md](DOCKGE_100_OPERATOR.md), [RAG_148_TO_110_MIGRATION.md](RAG_148_TO_110_MIGRATION.md). **GPU OC (Linux):** [GPU_OC_LACT_OPERATOR.md](GPU_OC_LACT_OPERATOR.md) (`inference` / `pool-opt-in` LACT; not `apps` / `hub` apt / not `orchestrator` Windows).

## Current deployment plan (operator)

> **PRIMARY WORKING SET (2026-08) — inference core + opt-in.** Always-on GPU
> shards: **`inference` / `orchestrator` / `hub`**. **inference opt-in:** **`gaming-a` / `gaming-c` /
> `gaming-b` / `secondary` / `pool-opt-in`** (never required for core green). Max inference
> all-five opt-in ~**84 GB** physical / **70.0 GB** tensor-split (`12,8,5,9,9,10,7,5,5`). Production =
> **Qwen3.6-27B**; **`frontier`** reserved for dense **~70–72B Q4** exclusive
> via Pool72 (fit researched in
> [experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md](experimental/UI_DRIVEN_GPU_MODEL_RESEARCH.md)).
> Join: [inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md). Plan:
> [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).
> Older Petals / four-host MoE paragraphs below are **historical** unless marked current.

> **April 2026 architecture shift + GPU swap:** the "brain"
> (`alfa-ai/deploy` stack: API, LiteLLM, Petals gateway, nginx) moved
> **from `apps` to `hub` (hub Scale 25.04)**, and the GPUs have been
> physically swapped between the two hosts. Rationale:
>
> - `hub` has a **Ryzen 9 7900X** (Zen4, 12c/24t, DDR5-5200) — the
>   fastest CPU in the cluster. Under the **June 2026 plan** it runs **only** the
>   **`qwen3:8b`** `operator_internal` model (Lane A); no sub-frontier chat —
>   brain/API. **Petals on `hub` retired** (historical announce `.157`).
>   **Embeddings** = **`qwen3-embedding:4b`**
>   on **`gaming-c`** (primary) + **`gaming-b`** (cold-standby). **CPU chat pool:** **`gaming-c`**
> **June 2026 GPU tier replan (2026-06-26, G-rev):** sub-frontier = **`qwen3.6:35b-a3b`**
> via **llama.cpp RPC** on **`hub` 5060 + `apps` 1660S + `orchestrator` 3060** (coordinator
> **`hub` CPU `:31360`**); code = **`qwen3.6-27b`** on **`inference` 3060+3050** local
> dual-GPU **`:31358`**. **`gaming-c` `qwen3.5:27b` removed.** See
> [FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md) Phase **G-rev**.
> - `hub` uses a **ZFS hot dataset for Ollama** (e.g. `ssd/ollama` → `/mnt/ssd/ollama`)
>   with a **cold mirror** under `/mnt/HDDs/Alfa-AI/models/ollama` — see
>   [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md). (A dedicated NVMe
>   data pool is optional; boot NVMe may be reserved for hub `boot-pool`.)
> - **GPU swaps (applied):** the RTX 3060 12 GB moved from `apps` → `hub`;
>   then `apps` and `secondary` swapped 6 GB cards so `apps` now runs GTX 1660 Super
>   and `secondary` now runs RTX 3050.
> - **April 2026 rebalance move:** the RTX 5060 8 GB moved from `gaming-c` → `hub`,
>   and `gaming-c` received a new RTX 5070 12 GB Blackwell card. This keeps stronger
>   Petals capacity on `hub` while increasing `gaming-c` shard headroom.
> - `apps` (UBUNTU-PRO-WEBSITES) **used to be** the monolithic apps host. After the 2026 dedicated-VM split (100 ALFA-AI, 102 MARKET, 103 ATEMS, 106 ProBilliards, 107 Grafana), many repos moved. See the **SSoT** [REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md). What remains on 105 is documented there. Old assumption "everything apps on 105" is no longer true.
>   VMs, the Petals gateway (kept here as a fault-domain hedge), and a
>   smaller Petals worker (GTX 1660 Super 6 GB).
> - **Network (2026-09-04 SSoT):** **`br1` is the LAN.** IPv4 **only on `br1`:**
>   `hub/24` (mgmt) + `storage/32` (NFS bind VIP). Cabinet NICs (`enp6s0`,
>   `enp7s0`, both BCM, USB) are **`br1` members** -- one L2 domain, not
>   separate planes. **`.157` / `.173` retired.** Post Init must **not** assign
>   IPv4 to bridge members. Stale: Jun 2026 "aliases on np0 / np1 unused"; Jul
>   2026 "triple-NIC split." See [hub_111_10G_NIC.md](hub_111_10G_NIC.md).
>   **Jun 2026 `iperf3` (same-L2 / `br1`):** ~937-948 Mbit/s from `apps`.
>   Procedure: [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md).
>
> **Frontier engine (always-on set, Jul 2026 inference):** **27B code** via **4-shard**
> llama.cpp RPC pool — CPU coordinator **`hub:31360`** (7900X); shards **`inference`**
> **inference (Jul 2026):** **`hub`** = **RTX 3050** pool tail shard **`:31353`** + **CPU
> coordinator `:31360`** (only GPU on `hub`; **5060 moved to `inference` `:31357`**).
> Shards: **`inference`** 3060+5060 (`:31356`/`:31357`), **`orchestrator`** `:31350`, **gpu-248 `secondary`**
> `:31355`, **VM100 `pool-opt-in`** `:31354`, **`hub` RTX 3050** `:31353`. **`PARALLEL=10`**, **`CTX_SIZE=163840`** (16384/slot).
> **35B MoE** uses same **`:31360`** slot when 27B stopped (mutual exclusion).
> **RAG embed + rerank** on **`rag` CPU** (`:11435` + `:8360`; **both mandatory**).
> Cutover from `inference` 2026-07-18. **`pool-opt-in`** is inference shard-only (`:31354`) — see [RAG_148_TO_110_MIGRATION.md](RAG_148_TO_110_MIGRATION.md).
> **Frontier / frontier-code** = same Qwen3.6-27B RPC pool (Petals 70B retired).
> Brain (API/LiteLLM/nginx) on **`hub`**. SSoT:
> [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).
>
> **inference opt-in (`gaming-a` / `gaming-c` / `gaming-b` / `secondary` / `pool-opt-in`):** rpc-server shards
> when joined at start (never required for core green). **`gaming-c` / `gaming-b`** also run
> 7B QLoRA train (14B archived on hub HDD) — blocked from inference opt-in while `alfa-train.lock` exists. RAG embed +
> rerank stay on **`rag`**. `pool-opt-in` is inference shard-only when opted in.
>
> See [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) for the current brain
> operator guide, [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md) for the
> apps-host guide, [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) for
> the hub layout, and [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md)
> for the NVMe pool setup.

## Nodes — summary table

| Node | LAN IP | CPU / RAM | GPU | Role (April 2026, post-swap) |
|------|--------|-----------|-----|------------------------------|
| **hub Scale 25.04** (`hub`) | `hub` (mgmt) + `storage` (NFS VIP on **`br1`**) | **Ryzen 9 7900X** 12c/24t / **~46 GiB** RAM (`free`; **2×24 GB** DDR5 **ECC UDIMM** @ **4800 MT/s** — hardware capture below; AsrockRack **B650D4U-2L2T/BCM**) | **RTX 3050 6 GB** (Ampere, `nvidia-smi` GPU 0 only — Jul 2026) | **Brain** (api, litellm, nginx, DB) + **27B CPU coordinator** `:31360` + **3050 pool shard** `:31353`. **Petals retired.** Hub image build + GGUF cache. Dockge via hub Apps at `:31014`. **`br1`** = cabinet L2 (BCM + i210 + USB). |
| **Ubuntu web-sites** (apps host) | `apps` | **Proxmox VM 105 on `pve-i5` / `hypervisor`** (i5-9600K host, **48 GiB** — was 64 GiB; **16 GiB moved to `secondary` build** 2026-07-09); guest **5** vCPU / **32 GB** | **None (CPU-only)** — 1660S passthrough moved to VM100; **no GPU required** (2026-07-30) | Apps, bot postgres/redis, contracts-bot. **Edge + inference hub moved to `inference`**. **Not** a inference GPU shard. **Petals retired.** |
| **Win11 desktop** (`WOLF1`; formerly `hub-93`) | `orchestrator` | **Ryzen 9 7900X** 12c/24t / **32 GB** DDR5 | **1×** RTX 3060 **12 GB** | **Dockge + llama.cpp `rpc-server` `:31350` (27B pool shard). No coordinator on `orchestrator`; `:31355` retired (2nd GPU removed 2026-06-21). Petals and Petals gateway retired.** |
| **gaming-worker-b** | `orchestrator` | **i7-11700** 8c/16t / 64 GB (**ASRock Z590**) | RTX 5070 **12 GB** (Blackwell) | **inference opt-in RPC shard `:31358`** (+ Pool72/80). 7B train worker (14B archived). Coordinator is **`hub:31360`**, not gaming-worker-b. RAG is **`rag`**, not embed-on-gaming-worker-b. **Petals retired.** Win11/WSL. Dockge agent `:5001`. GPU stats: **worker-monitor `:31331`**. |
| **gaming-worker-c** | `orchestrator` | i7-12700 / 64 GB | RTX 5070 **12 GB** | **inference opt-in RPC `:31351`** (+ Pool72/80) + 7B train rdzv (14B archived). **Petals retired.** No production embed here (RAG is `rag`). GPU stats: **worker-monitor `:31331`**. |
| **gaming-worker-a** | `orchestrator` | **i5-9600K** 6c/6t / **64 GB DDR4** (**Gigabyte Z390 GAMING X**) | RTX 5060 **8 GB** (Blackwell, PCIe **3×8**) | **Opportunistic inference RPC shard** `:31352` (8 GB tensor slice). **Petals retired.** Win10/WSL. Dockge agent `:5003` (not 5001 — OS conflict). GPU stats: **worker-monitor `:31331`**. Prometheus job `gaming-worker-a-219` stays on `monitor`. |
| **ai-148** | `orchestrator` on **`bond0`** (active-backup: **`eno1`** primary + **`nic_usb`**) | **i7-9700K** 8c/8t / **48 GiB** (**Gigabyte Z390 AORUS PRO**) | **RTX 5060 8 GB** (GPU 0) + **RTX 3060 LHR 12 GB** (GPU 1) — Jul 2026 `nvidia-smi` | **27B pool shards** `:31356`/`:31357` + **cluster hub** (verify, edge `:8420`, SSH jump). Coordinator on **`hub`**. [ai-148/README.md](../deploy/cluster-members/inference-coordinator/README.md). |
| **`secondary`** (`Nickey-Nakita`; rename **`gpu-248`** optional) | **`orchestrator`** on **Wi-Fi** (static; USB Ethernet unplugged 2026-09-14, MAC `58:04:4f:25:8f:9f`). Do not opt into inference on Wi-Fi (high RTT). | **i7-6700K** 4c/8t / **16 GiB** (the **16 GiB DIMM moved from `pve-i5` `hypervisor`** 2026-07-09) (**MSI MS-7982**) | **GTX 1070 8 GB** (Pascal; iGPU desktop) | **27B pool shard `:31355`** (opt-in at start; hub `cuda128-pascal`). Operator: [DOCKGE_248_OPERATOR.md](DOCKGE_248_OPERATOR.md). [RAG_248_VM100_SHARD.md](../.cursor/plans/RAG_248_VM100_SHARD.md). |
| **ALFA-AI** (Proxmox VM 100 on **`pve-i5` `hypervisor`**) | `orchestrator` (`operator`, `~/alfa-ai`) | **4 vCPU / 16 GB**; root LV **~30 GB** (Proxmox disk 100 GB) | **GTX 1660 Super** (passthrough from VM105) | **27B pool shard `:31354` only** (opt-in at start; RAG retired to CPU on `rag` — [RAG_248_VM100_SHARD.md](../.cursor/plans/RAG_248_VM100_SHARD.md)). Brain+DB on **`hub`**. Operator: [DOCKGE_100_OPERATOR.md](DOCKGE_100_OPERATOR.md). |
| **VM110** (Proxmox VM 110 on **`pve-i5` `hypervisor`**) | `orchestrator` (`operator`, `~/alfa-ai`) | **4 vCPU / 16 GiB** (i5-9600K host, `cpu:host`); **CPU-only** | — | **CPU RAG production** embed `:11435` + rerank `:8360` (cutover from `inference` 2026-07-18). Operator: [DOCKGE_110_OPERATOR.md](DOCKGE_110_OPERATOR.md), [RAG_148_TO_110_MIGRATION.md](RAG_148_TO_110_MIGRATION.md). Agent SSH from `orchestrator`: `id_ed25519_93_110`. |
| **Raspberry Pi 4** | `orchestrator` (`operator`, hostname `pi4`) | **BCM2711** / RAM per board | — (BLE) | **Edge IoT radio:** Victron BLE (+ optional Sungold USB) → MQTT on **`apps:1883`**. HA/Mosquitto **moved to `apps`**. Agent SSH: `id_ed25519_93_223` ([PI4_VICTRON_OPERATOR.md](PI4_VICTRON_OPERATOR.md), [HOMEASSISTANT_105_OPERATOR.md](HOMEASSISTANT_105_OPERATOR.md)). |
| **Raspberry Pi 5** | `orchestrator` (`operator`, hostname `raspberrypi`) | **BCM2712** / RAM per board | — (BLE) | **House edge:** AdGuard DNS + Theengs BLE → **`apps:1883`**. **Always `edge`**. [PI5_OPERATOR.md](PI5_OPERATOR.md). Agent SSH: `id_ed25519_93_223` (shared with Pi4). |

> **Linux hub policy:** Every Ubuntu/WSL node on the LAN that builds cluster
> images, syncs wheels, or bind-mounts shared HF/Ollama paths must run
> **`scripts/mount_nfs_models.sh`** so **`/mnt/cluster`** points at hub
> (see [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) §3). Windows
> nodes use SMB to the same dataset instead.

## Machine stats (at a glance)

Quantitative summary per host. **GPU fields:** confirm with `nvidia-smi` on the
box if anything drifts. **Blocks** are approximate for **Llama-3.3-70B-Instruct** NF4
(~55 GB on-disk). See [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md) for the full
tier matrix.

### Hardware

| Node | Primary LAN | CPU (c/t) | RAM | GPU | VRAM | CC |
|------|-------------|-----------|-----|-----|------|-----|
| `hub` hub | `hub` | Ryzen 9 7900X (12/24) | ~46 GiB (2×24 GB DDR5 ECC UDIMM 4800) | RTX 3050 | 6 GB | 8.6 |
| `apps` Ubuntu (VM on `pve-i5.home`/`hypervisor`) | `apps` | i5-9600K host (5 vCPU guest, `cpu:host`) | 32 GB guest (host **48 GiB**; was 64 GiB) | **None (CPU-only)** | — | — |
| `orchestrator` Win11 (WOLF1) | `orchestrator` | Ryzen 9 7900X (12/24) | 32 GB DDR5 (2×16 Corsair 6400 kit @ 4800, EXPO off) | **1×** RTX 3060 (2nd removed 2026-06-21) | 12 GB | 8.6 |
| `inference` ai-148 | `orchestrator` | i7-9700K (8/8) | 48 GiB | RTX 5060 + RTX 3060 LHR | 8 + 12 GB | 8.6 / 12.0 |
| `rag` VM110 | `orchestrator` | i5-9600K host (4 vCPU guest, `cpu:host`) | 16 GiB | — (CPU-only) | — | — |
| `hypervisor` pve-i5 (Proxmox) | `orchestrator` | i5-9600K (6/6) | **48 GiB** (46 GiB usable; live 2026-07-09) | GTX 1660S passthrough to VMs | 6 GB | 7.5 |
| `secondary` Nickey-Nakita | `orchestrator` | i7-6700K (4/8) | **16 GiB** (from `hypervisor`) | **GTX 1070 8 GB** (Wi-Fi; poor RPC — keep opt-in off on Wi-Fi) | 8 GB | 6.1 |
| `gaming-b` gaming-worker-b | `orchestrator` | i7-11700 (8/16) | 64 GB DDR4 | RTX 5070 | 12 GB | 12.0 |
| `gaming-c` gaming-worker-c | `orchestrator` | i7-12700 (12/20) | 64 GB DDR4 | RTX 5070 | 12 GB | 12.0 |
| `gaming-a` gaming-worker-a | `orchestrator` | i5-9600K (6/6) | 64 GB DDR4 | RTX 5060 | 8151 MiB | 12.0 |
| **Pi4** Victron/HA | `orchestrator` | Raspberry Pi 4 | per board | — | — | Agent SSH `orchestrator`: `id_ed25519_93_223` |
| **Pi5** Victron/HA | `orchestrator` | Raspberry Pi 5 | per board | — | — | Same key as Pi4; [PI5_OPERATOR.md](PI5_OPERATOR.md) |

### Cluster roles (live — inference + brain + RAG)

Petals columns and swarm totals below this heading used to be live. **Petals is retired.** Do not start `petals-worker` or a Petals gateway. Historical VRAM math: [history/](history/).

| Node | llama.cpp RPC | Other live role | VRAM | Dockge |
|------|----------------|-----------------|------|--------|
| `hub` | **`rpc-server` `:31353`** + **CPU coordinator `:31360`** | Brain + DB + LiteLLM `:8413` + API `:8420` | 6 GB | Apps `:31014` |
| `apps` | **None** (CPU-only apps) | Remaining websites/bots | — | agent `:5001` |
| `orchestrator` | **`rpc-server` `:31350`** (core shard) | Dockge UI + cluster orchestrator | 12 GB | UI `:5002` |
| `inference` | **`rpc-server` `:31356`/`:31357`** (core) | Edge `:8420` | 8 + 12 GB | — |
| `rag` | **None** | **RAG** embed `:11435` + rerank `:8360` | — | — |
| `pool-opt-in` | **`rpc-server` `:31354`** (opt-in) | Not RAG | 6 GB | — |
| `secondary` | **`rpc-server` `:31355`** (opt-in) | — | 8 GB | — |
| `gaming-b` | **`rpc-server` `:31358`** (inference opt-in) | Gaming / train | 12 GB | agent `:5001` |
| `gaming-c` | **`rpc-server` `:31351`** (inference opt-in) | Gaming / train | 12 GB | agent `:5001` |
| `gaming-a` | **`rpc-server` `:31352`** (opt-in) | Gaming | 8 GB | agent `:5003` |

**Production inference:** Qwen3.6-27B on coordinator **`hub:31360`**. **35B MoE is retired** (same slot only if an operator explicitly revives it). **`frontier` / `frontier-code`** share the 27B pool. See [FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).

**NVIDIA drivers:** `hub` **550.142** (CUDA **12.4**, Apr 2026); `apps`
**590.48.01** (CUDA **13.1**, Apr 2026); `orchestrator` **610.62** (WDDM, **2026-06-21**
capture). See [Operator hardware captures](#operator-hardware-captures).

### Commands to capture hardware (operator)

Use these when validating or updating the tables above. **GPU:** `nvidia-smi` is
the source of truth for model name, VRAM, and CUDA capability on NVIDIA hosts.

**Linux** (Ubuntu, hub Scale shell, WSL — adjust if a tool is missing):

```bash
hostnamectl 2>/dev/null; echo '---'; lscpu; echo '---'; free -h; echo '---'
nvidia-smi 2>/dev/null || lspci -nn | grep -iE 'vga|3d|nvidia'
echo '---'; lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
```

Optional (RAM module detail, requires root): `sudo dmidecode -t memory | grep -E '^(Size|Locator|Speed)'`

**LAN latency / throughput (all cluster IPs):** run
[`scripts/cluster_lan_speedtest.sh`](../scripts/cluster_lan_speedtest.sh) from a
Linux host on the same subnet. The orchestrator runs **ping + iperf3 upload +
iperf3 download** against every target by default, parses iperf3 JSON, prints
an aligned summary table, and emits per-host remediation hints (with the exact
bootstrap command) for any target that fails. Flags: **`--ping-only`**,
**`--no-ping`**, **`--hosts ip,ip,...`**, **`--file hosts.txt`**, **`--port`**,
**`--duration`**, **`--streams`**, **`--auto-install`** (auto-installs `iperf3`
on the runner via apt/dnf/apk/pacman). Full transcript is logged to
`cluster-speedtest-<UTC>.log` in CWD. Exit code **0** = all green,
**1** = one+ target failed, **2** = runner environment not ready.
See [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md) for **`hub`** multi-NIC
`iperf3 -B` binding.

**Target prep — one command per host, idempotent, survives reboots:**

- **Linux** (hub `hub`, Ubuntu `apps`):

  ```bash
  bash scripts/iperf3-bootstrap.sh           # start/refresh server + firewall
  bash scripts/iperf3-bootstrap.sh --status  # report state
  bash scripts/iperf3-bootstrap.sh --stop    # teardown
  ```

- **Windows `operator-93`** (repo at `C:\alfa-ai`), from an **Administrator**
  PowerShell:

  ```powershell
  cd C:\alfa-ai ; git pull
  powershell -ExecutionPolicy Bypass -File scripts\iperf3-bootstrap.ps1
  powershell -ExecutionPolicy Bypass -File scripts\iperf3-bootstrap.ps1 -Status
  powershell -ExecutionPolicy Bypass -File scripts\iperf3-bootstrap.ps1 -Stop
  ```

- **Windows workers `gaming-worker-b-249`, `gaming-worker-c-59`, `gaming-worker-a-219`**
  (repo at `C:\alfa-ai-worker`), from an **Administrator** PowerShell:

  ```powershell
  cd C:\alfa-ai-worker ; git pull
  powershell -ExecutionPolicy Bypass -File scripts\iperf3-bootstrap.ps1
  powershell -ExecutionPolicy Bypass -File scripts\iperf3-bootstrap.ps1 -Status
  powershell -ExecutionPolicy Bypass -File scripts\iperf3-bootstrap.ps1 -Stop
  ```

Both bootstraps: auto-start via **WSL Docker Engine** (Windows) or the package manager
(Linux), open the firewall on TCP **5201**, and launch a
`networkstatic/iperf3 -s -p 5201` container with `--restart unless-stopped`.

**Secondary `hub` addresses (`storage`; `.157` retired):** hub **`br1`** aliases on the same L2; TCP **5201** binds on `hub` unless you re-run iperf3 with `-B <alias-ip>`.

**Recorded LAN sweep — 2026-06-26** (from `apps`, `cluster_lan_speedtest.sh`, iperf3 3.16, 10 s, 4 TCP streams, port 5201; all online targets had `iperf3-bootstrap` running). Full tables: [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md).

| Target | Ping avg | Upload (Mbps) | Download (Mbps) | Status |
|--------|----------|---------------|-----------------|--------|
| `hub` mgmt | 0.34 ms | 946.9 | 941.0 | OK |
| `storage` NFS | 0.34 ms | 947.7 | 940.9 | OK |
| `.157` Petals | 0.43 ms | 947.6 | 941.0 | OK |
| `orchestrator` WOLF1 | 0.49 ms | 947.4 | 941.1 | OK |
| `inference` ai-148 | 0.38 ms | 946.9 | 936.4 | OK |
| `gaming-a` / `gaming-c` / `gaming-b` | DOWN | — | — | offline (no ping) |

**Direct path `orchestrator` → `hub`** (WSL Docker iperf3 client on `orchestrator`, same params): **952 Mbps** upload / **941 Mbps** download — still **~1 GbE-class** despite faster local NICs.

**Negotiated link speeds (Jun 2026, local `ethtool` / `Get-NetAdapter`):**

| Node | Active link | Measured LAN throughput | Notes |
|------|-------------|---------------------------|-------|
| `orchestrator` | **10 Gbps** X540 bridge (`Network Bridge`, `orchestrator/24`) | not re-measured 2026-10-02 | **Supersedes Jun 2026 Realtek row.** 92A+92B bridged; **Large Send Offload V2 Disabled** on both. SSoT: [WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md) |
| `apps` | virtio (`enp6s18` in VM); physical USB-Eth on `hypervisor` | ~947 Mbps (runner ceiling) | Limits any test sourced from `apps` |
| `inference` | **1 Gbps** (`eno1` + USB on `bond0`) | ~937–947 Mbps | At link cap |
| `hub` | **`br1`** (BCM + i210 + USB members, 2026-09-04) | ~941-948 Mbps from `apps` (same-L2 / `br1`) | 2026-06-27: BCM at **1000 Mb/s** on Yuanley path; see hub_NIC_SPEEDTEST |
| `gaming-a` / `gaming-c` / `gaming-b` | **2.5 GbE** expected (router port) | not tested | powered off at scan time |

**Windows 10 / 11** (cmd or PowerShell — hardware info):

```text
systeminfo
```

PowerShell (more structured CPU/RAM):

```powershell
Get-CimInstance Win32_Processor | Format-List Name, NumberOfCores, NumberOfLogicalProcessors
[System.Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
nvidia-smi
```

### Operator hardware captures

Dated dumps from the [commands above](#commands-to-capture-hardware-operator). Add
new headings when you run on other nodes. **nvidia-smi** excerpts are the
authoritative GPU record.

#### `orchestrator` (`pve-i5.home` / Proxmox host of VM 105 + VM 100) — 2026-07-09 (RAM change, live verify)

> **Hardware change (2026-07-09):** Operator removed **16 GiB** from this host for the
> planned **`secondary`** build. **64 GiB → 48 GiB** (one **16 GiB** DIMM removed from the
> prior **4× 16 GiB** layout).

- **Session:** `root@pve-i5` (Proxmox shell on `orchestrator`).
- **Memory (`free -h`, 2026-07-09):** **46 GiB** total (**~48 GiB** installed; kernel
  reserved); **21 GiB** used, **25 GiB** available at capture (VM105 + VM100 running).
  **8.0 GiB** swap (unused).
- **DIMMs:** module list pending — run as root (no `sudo` on Proxmox):
  `dmidecode -t memory | grep -E 'Size:|Locator:|Part Number:'`
- **Prior authoritative capture (2026-06-22):** **64 GiB** — **4× 16 GB** DDR4-2133
  (2× Timetec + 2× Samsung). See section below for full host record.
- **Impact:** VM 105 (`apps`) and VM 100 (`pool-opt-in`) guest RAM allocations unchanged;
  hypervisor headroom reduced by 16 GiB — monitor `free -h` on `pve-i5` under load.

#### `orchestrator` (`pve-i5.home` / Proxmox host of `apps`) — 2026-06-22

> **Authoritative Proxmox host record for `apps`.** Hostname **`pve-i5.home`**
> (was **`pvei7`** before 2026-06-22 fresh NVMe reinstall). The `apps` apps host
> is **Proxmox VM 105 (`UBUNTU-PRO-WEBSITES`)** on this box. The 2026-04-18
> `apps` capture below (i7-6700K / 8 vCPU / 53 GiB) is **SUPERSEDED**.

**Host `pve-i5.home` (`orchestrator`):**

- **Role:** **Proxmox VE** hypervisor for **VM 105 = the `apps` apps host**
  (priority). **Fresh OS on NVMe started 2026-06-22** — restore VM 105 from hub
  backup at `/mnt/HDDs/Alfa-AI/backups/pvei7-105/` on `hub`.
- **OS / kernel:** Debian 12 (bookworm) on **NVMe** (fresh install 2026-06-22;
  prior install was `pvei7` on degraded SATA `rpool`, retired).
- **Board:** **MSI B365M PRO-VDH (MS-7C39)**, firmware **1.40**, LGA1151.
- **CPU:** Intel **i5-9600K** — **6c/6t** (no HT), Coffee Lake; **VT-x + VT-d**.
  Idle policy: `intel_pstate` governor **`powersave`**, HWP EPP
  **`balance_performance`** (not `performance`, which locks HWP to max P-state).
  See [CLUSTER_IDLE_POWER.md](CLUSTER_IDLE_POWER.md).
- **RAM:** **64 GiB** (62 GiB usable) — **4× 16 GB DDR4-2133** dual-rank,
  dual-channel (2× Timetec + 2× Samsung, identical spec); SMBIOS max **64 GB**
  (at the board ceiling). **Upgraded from 32 GB on 2026-06-21.**
  *(Superseded 2026-07-09 — one 16 GiB DIMM removed for `secondary` build; expected **48 GiB** — verify live.)*
- **GPU:** **NVIDIA GTX 1660 SUPER** (TU116, 6 GB) — full passthrough group at
  `01:00.0/.1/.2/.3` (VGA+audio+USB-C) bound to **VM 105**.
- **IOMMU/VT-d:** **enabled.** GRUB cmdline `quiet intel_iommu=on iommu=pt`;
  BIOS **Intel VT-D Tech = Enabled**. **UEFI boot** (EFI install, kernel
  **7.0.2-6-pve** on 2026-06-22 reinstall).
- **ZFS ARC:** capped at **8 GB** (`/etc/modprobe.d/zfs.conf`, live + initramfs).
- **Storage:** **Samsung 990 PRO 1 TB** NVMe — **Proxmox OS + VM storage** (fresh
  install 2026-06-22). Layout after post-install LVM resize: **`pve-root` 400 GB**
  (OS + vzdump staging), **`pve/data` thin pool 500 GB** (`local-lvm` for VMs),
  **8 GB swap**. Prior SATA SSDs (`rpool`, degraded RAID0) **retired / not in use**.
  Installer default `maxroot` (~96 GB) was expanded via thin-pool recreate (thin
  pools cannot shrink in place on this LVM build).

**VM 105 (`UBUNTU-PRO-WEBSITES`) = the `apps` apps host:**

- **vCPU:** **5 cores / 1 socket**, `cpu: host` (guest now sees the **i5-9600K**
  feature set; the April i7-6700K reading was the prior host). 1 core left for
  the Proxmox host + disk iothread.
- **RAM:** **32 GB**, **`balloon: 0`** (GPU passthrough pins guest RAM, so it is
  fixed). Was 24 GB before the 2026-06-21 RAM upgrade.
- **Disk:** **500 GB** on the **`nvme`** pool (virtio-scsi-single, `iothread=1`,
  `discard=on`, `ssd=1`); `efidisk0` also moved to `nvme`. Off the failing
  `rpool` stripe as of 2026-06-21.
- **GPU:** **GTX 1660 SUPER 6 GB** via PCI passthrough (`hostpci`, group above).
- **Network:** `apps`. Restored and running 2026-06-22 (`qmrestore`
  from hub NFS). Guest OS was Ubuntu 24.04 LTS at restore; **Ubuntu 26.04.1
  LTS** as of 2026-08-28 (`7.0.0-30-generic`).
- **Backups (hub — use for restore):** `vzdump-qemu-105` on `hub` at
  `/mnt/HDDs/Alfa-AI/backups/pvei7-105/` — **56 G (2026-04-16)**, **192 G
  (2026-06-17)**, plus **pre-reinstall (2026-06-22)** GUI backup. **Restore the
  newest 2026-06-22 set** after fresh install.

#### `hub` (hub / hub) — 2026-04-18

- **Prompt:** `hub%` (shell on the hub host).
- **hostnamectl:** static hostname **hub**, chassis **server**, **AsrockRack**
  **B650D4U-2L2T/BCM**, firmware **10.18**. OS base **Debian GNU/Linux 12
  (bookworm)**; kernel **Linux 6.12.15-production+hub** (hub Scale).
- **CPU (lscpu):** **AMD Ryzen 9 7900X** — **12** cores / **24** threads, 1
  socket, max **~5733** MHz (matches the summary table).
- **Memory (`free -h`):** **46** GiB total; **0** B swap at capture (aligned with
  summary table **~46 GiB**).
- **DIMMs (`sudo dmidecode -t memory`) — 2026-04-22, authoritative install:**
  - **Array:** multi-bit **ECC**; **4** slots; **128 GB** max (per SMBIOS).
  - **Populated:** **2× 24 GB** DDR5 **ECC UDIMM** (unbuffered), **rank 1**, **72-bit**
    bus (64 data + ECC), **4800 MT/s** configured (JEDEC; module and configured
    speed both **4800**).
  - **Layout:** **P0 CHANNEL A / DIMM 1** and **P0 CHANNEL B / DIMM 1** (DIMM **0**
    empty on each channel — typical 1-DPC dual-channel fill).
  - **Part number (both sticks):** `AVW723GUA1K0480P06-BAB7` (module manufacturer
    ID **0xF7** per SPD; human-readable vendor not decoded in this capture).

  ```text
  Physical Memory Array
          Error Correction Type: Multi-bit ECC
          Maximum Capacity: 128 GB
          Number Of Devices: 4
  Memory Device (×2 populated)
          Size: 24 GB
          Locator: DIMM 1
          Bank Locator: P0 CHANNEL A  /  P0 CHANNEL B
          Type: DDR5
          Type Detail: Synchronous Unbuffered (Unregistered)
          Speed: 4800 MT/s
          Configured Memory Speed: 4800 MT/s
          Part Number: AVW723GUA1K0480P06-BAB7
          Rank: 1
          Total Width: 72 bits
          Data Width: 64 bits
  ```

- **GPU (`nvidia-smi`):** driver **550.142**, **CUDA 12.4**; **GeForce RTX 3060**,
  **12288** MiB — **~4210** MiB in use by **`python3`** at capture (Ollama /
  inference workload).
- **Disk (`lsblk`):** **nvme0n1** **~931** GB (three partitions — OS/boot layout);
  **sda–sdi** nine **~3.6** TB disks (single partition each, ZFS members);
  **sdj** / **sdk** two **~465** GB disks; **loop1** **~367** MB (snap/overlay).

`free -h`:

```text
               total        used        free      shared  buff/cache   available
Mem:            46Gi        19Gi        14Gi        84Mi        13Gi        26Gi
Swap:             0B          0B          0B
```

`nvidia-smi` (trimmed):

```text
Sat Apr 18 20:20:06 2026
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.142                Driver Version: 550.142        CUDA Version: 12.4     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|=========================================+========================+======================|
|   0  NVIDIA GeForce RTX 3060        Off |   00000000:01:00.0 Off |                  N/A |
|  0%   38C    P8             11W /  170W |    4210MiB /  12288MiB |      0%      Default |
+-----------------------------------------+------------------------+----------------------+
| Processes:                                                                              |
|    0   N/A  N/A     11733      C   python3                                      4204MiB |
+-----------------------------------------------------------------------------------------+
```

Block devices (summary — loops omitted except `loop1`):

```text
NAME          SIZE TYPE MOUNTPOINTS
loop1       366.8M loop
sda           3.6T disk
└─sda1        3.6T part
sdb           3.6T disk
└─sdb1        3.6T part
sdc           3.6T disk
└─sdc1        3.6T part
sdd           3.6T disk
└─sdd1        3.6T part
sde           3.6T disk
└─sde1        3.6T part
sdf           3.6T disk
└─sdf1        3.6T part
sdg           3.6T disk
└─sdg1        3.6T part
sdh           3.6T disk
└─sdh1        3.6T part
sdi           3.6T disk
└─sdi1        3.6T part
sdj         465.8G disk
└─sdj1      465.8G part
sdk         465.8G disk
└─sdk1      465.8G part
nvme0n1     931.5G disk
├─nvme0n1p1     1M part
├─nvme0n1p2   512M part
└─nvme0n1p3   931G part
```

#### `orchestrator` (`Nickey-Nakita`) — 2026-07-16 (gpu-248 inference shard)

- **Session:** `operator@orchestrator` (SSH from `orchestrator` `operator`; key auth OK).
- **Status:** **GTX 1070 seated** — operator must install NVIDIA driver + Docker +
  hub `cuda128-pascal` image before first orchestrator join (gate in
  [DOCKGE_248_OPERATOR.md](DOCKGE_248_OPERATOR.md)).
- **hostnamectl:** **`Nickey-Nakita`**; **MSI MS-7982**; Linux Mint **22.3**;
  kernel **6.17.0-35-generic**.
- **CPU (lscpu):** Intel **i7-6700K** @ **4.00 GHz**; **4c/8t**; VT-x on.
- **Memory (`free -h`, 2026-07-09):** **15 GiB** reported total (`MemTotal`
  **16,243,952 kB**); **2.0 GiB** swap. **16 GiB installed — sole DIMM is the 16 GiB
  module moved from `pve-i5` `hypervisor`** (2026-07-09). Operator may add RAM later if
  needed; **16 GiB is sufficient** for Mint desktop + shard-only Docker (see plan).
- **GPU:** **GTX 1070 8 GB** (Pascal sm_61) — compute-only; **Intel HD 530** iGPU for desktop.
  Verify with `nvidia-smi` (~0 MiB before shard start).
- **Network (2026-09-14):** **Wi-Fi only** on `wlx58044f258f9f` (`Auto StarWarz2`,
  `ipv4.method manual` **`orchestrator/24`**, gateway/DNS `orchestrator`).
  Onboard `enp2s0` is DOWN; USB Ethernet unplugged (cabinet AXE300 1G port idle).
  Keep `secondary` out of the AXE300 DHCP pool (reservation on Wi-Fi MAC
  `58:04:4f:25:8f:9f`). Wi-Fi RTT from `orchestrator` is ~70-100 ms; do **not** opt into
  inference `:31355` until USB Ethernet is back (RPC is latency-sensitive). See
  [PI_NET_EXCLUSIVE.md](PI_NET_EXCLUSIVE.md) for the one-IP-per-host rule.
- **SSH:** **`openssh-server`**. **`operator@orchestrator`** from `orchestrator` (passwordless
  ed25519, 2026-07-09). Operator account **`nickey`** also exists.
- **Role:** opt-in inference rpc-server shard **`:31355`** (Start-Stop Y/N).
  Image: **`alfa-llamacpp-rpc:cuda128-pascal`**. See
  [DOCKGE_248_OPERATOR.md](DOCKGE_248_OPERATOR.md) and
  [.cursor/plans/RAG_248_VM100_SHARD.md](../.cursor/plans/RAG_248_VM100_SHARD.md).
- **Monitoring (2026-09-14):** `node_exporter` `:9100`, DCGM `:9400`, Dozzle `:7007`,
  Dockge `:5001` are up. Prometheus on **`monitor`** scrapes **`orchestrator`**
  (`monitoring` repo `hosts/orchestrator/`).

#### `orchestrator` (ai-148) — 2026-07-09 (authoritative; RAM re-verify)

- **OS (2026-08-28):** still Ubuntu **26.04.1 LTS**, running kernel
  **7.0.0-30-generic** after in-place `dist-upgrade` + reboot.
- **Session:** `operator@ai-148` (SSH from `orchestrator`).
- **Memory (`free -h`, 2026-07-09):** **~45 GiB** reported total (**48 GiB** installed;
  `MemTotal` consistent with 2026-06-28 upgrade); **4.0 GiB** swap.
- **Memory modules (`dmidecode -t memory`, 2026-07-09):**
  - **Channel A-DIMM0:** **16 GB** DDR4 **2133 MT/s** — TeamGroup **`W642GU44J9266NC`**
  - **Channel A-DIMM1:** **16 GB** DDR4 **2133 MT/s** — TeamGroup **`W642GU42J9266N8`**
  - **Channel B-DIMM0:** **8 GB** DDR4 **2133 MT/s** — Corsair **`CMK16GX4M2B3000C15`**
  - **Channel B-DIMM1:** **8 GB** DDR4 **2133 MT/s** — Corsair **`CMK16GX4M2B3000C15`**
- **Note:** A mistaken 2026-07-08 doc pass claimed **16 GiB removed from `inference`** for
  `secondary`; operator corrected — **`inference` unchanged at 48 GiB**. RAM for `secondary` came from
  **`pve-i5` `hypervisor`** instead (see below).

#### `orchestrator` (ai-148) — 2026-06-28 (superseded for RAM by 2026-07-09 re-verify)

- **Session:** `operator@ai-148` (SSH to `orchestrator`).
- **hostnamectl:** static **`ai-148`**, **Gigabyte Z390 AORUS PRO**, firmware **F10**;
  Ubuntu **26.04 LTS**, kernel **7.0.0-22-generic** x86_64.
- **CPU (lscpu):** Intel **i7-9700K** @ **3.60** GHz; **8** cores × **1** thread/core
  (**8c/8t**); max **4900** MHz; VT-x on.
- **Memory (`free -h`, 2026-06-28 post-upgrade):** **45** GiB total; **4.0** GiB swap
  (0 B used at capture). **Upgrade:** **16 GiB → 48 GiB** installed (2026-06-28).
- **Memory modules (`dmidecode -t memory`):**
  - **Channel A:** **2× 16 GB** DDR4 **2133 MT/s** — TeamGroup **`W642GU42J9266N8`**
    (DIMM0) + **`W642GU44J9266NC`** (DIMM1)
  - **Channel B:** **2× 8 GB** DDR4 **2133 MT/s** — Corsair **`CMK16GX4M2B3000C15`**
    (both DIMMs; kit rated 3000 MT/s, running **2133** at capture — verify XMP in BIOS)
- **GPU (`nvidia-smi`, 2026-06-28):** driver **595.71.05**
  - **RTX 3050 6 GB** (index 0, GA107, **cc 8.6**)
  - **RTX 3060 12 GB** (index 1, GA106 LHR, **cc 8.6**)
- **Disk (`lsblk`):** **nvme0n1** **931.5 GB**; LVM root **`ubuntu--vg-ubuntu--lv`**
  **929.5 GB** `/` (plus **2 GB** `/boot`) — expanded from prior **~100 GB** root LV.
- **Network (`ip -br addr`, bond applied 2026-06-22):**
  - **`bond0` → `orchestrator/24`** — **`PETALS_ANNOUNCE_IP`**
  - **Mode:** `active-backup`; **primary** `eno1` (`b4:2e:99:38:2f:c9`); backup **`nic_usb`**
    (`7c:c2:c6:46:ec:53`, was `enx7cc2c646ec53`)
  - Netplan: `/etc/netplan/01-ai148-bond.yaml`; installer DHCP config disabled
  - Apply: **`netplan apply`** (not `netplan try` — bonds revert unsupported on 26.04)
  - **Link speed (`ethtool`, 2026-06-26):** **1 Gbps** full duplex on **`eno1`**
    and USB backup **`nic_usb`**.
  - **Jun 2026 iperf3:** `apps → inference` **946.9 / 936.4 Mbps** — at **1 GbE** cap
    ([hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md)).
- **Prior capture (2026-06-22):** **16 GiB** RAM; NVIDIA driver not yet installed;
  root LV **~100 GB**. Supersedes that row for RAM, driver, and disk layout.
- **Supersedes:** planned **`secondary`** worker (i5-9600K / 32 GB / single 3050) — that
  host never came online; **do not re-IP this box to `secondary`.**

#### `orchestrator` (Win11) — 2026-06-21 (live capture, authoritative)

- **Hostname (`systeminfo`):** **WOLF1** (was `hub-93`).
- **OS:** Microsoft Windows 11 Pro for Workstations, build **10.0.26200**.
- **CPU (`Get-CimInstance Win32_Processor`):** **AMD Ryzen 9 7900X** 12-Core —
  **12** cores / **24** threads, base clock **4701** MHz.
- **Motherboard (`Win32_BaseBoard`):** ASUSTeK **ROG STRIX X870E-E GAMING WIFI**
  (Rev 1.xx); **BIOS** AMI **1203**, dated **2025-03-03**.
- **RAM (`Win32_PhysicalMemory`):** **2× 16 GB** Corsair **`CMH32GX5M2B6400C36`**
  (a **6400**-rated kit) running at **4800 MT/s** configured — **EXPO is NOT
  enabled**; effective speed is **DDR5-4800**. Total **~31.1 GiB**.
- **GPU (`nvidia-smi -L`, source of truth):** **1× NVIDIA GeForce RTX 3060
  12 GB** (Ampere, cc **8.6**) on PCI bus `01:00.0`, driver **610.62**. Plus the
  7900X's integrated **AMD Radeon Graphics** (iGPU). **The second RTX 3060 is no
  longer present** — `orchestrator` is now a **single discrete GPU** host (operator
  confirmed 2026-06-21: 2nd 3060 removed permanently). Prior docs listing **2×**
  3060 / **24 GB** are superseded.
- **Storage (`Win32_DiskDrive` / `Win32_LogicalDisk`):**
  - **Samsung SSD 870 EVO 1TB** (SATA) — **`C:`** ~854 GB usable, ~230 GB free.
  - **Samsung SSD 990 EVO Plus 1TB** (NVMe) — **`D:`** ~932 GB, ~603 GB free.
- **Network (`Get-NetAdapter`, 2026-06-26, historical):** Realtek **`Ethernet 2` at 5 Gbps** held **`orchestrator`**; both X540s were disconnected. **Superseded 2026-10-02** by [WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md):
  - **`orchestrator/24`**, gateway **`orchestrator`**, DNS **`orchestrator`** on **Network Bridge**.
  - **92A** X540 `98-B7-85-21-1F-D7` = **`Ethernet 2`**, Up **10 Gbps**, Yuanley.
  - **92B** X540 `98-B7-85-21-1F-D8` = **`Ethernet 5`**, Up **10 Gbps**, `hub` BCM.
  - Realtek `BC-FC-E7-E9-44-A7` = **`Ethernet 4`**, optional, may stay disconnected.
  - **Large Send Offload V2 (IPv4)** and **V2 (IPv6)** **Disabled** on both X540s (host upload fix, 2026-10-02).
  - `Ethernet N` names can change after a Windows network reset. Match **MAC**.

> **Swarm-total impact deferred:** the drop from 2× → 1× RTX 3060 reduces `orchestrator`
> from **24 GB → 12 GB** of Petals VRAM. The cluster-wide aggregates (the
> **76 GB** swarm total, the VRAM accounting table, the "8 GPUs / 7 hosts"
> counts) are **left unchanged in this pass** and flagged **PENDING RECOMPUTE**
> until `apps` and `hub` are also re-captured (operator request 2026-06-21).

## Cluster status (LAN)

Live roles are the **Nodes — summary table** and **Cluster roles** table above.
**Petals is retired.** Do not start gateways or `petals-worker`. The numbered
April 2026 Petals-era list that used to live here is superseded.

- **`hub`** — brain + DB + LiteLLM `:8413` + coordinator `:31360` + shard `:31353` + hub
- **`rag`** — production RAG `:11435` / `:8360`
- **`inference` / `orchestrator`** — core inference shards (+ `inference` edge)
- **`pool-opt-in` / `secondary`** — opt-in inference shards
- **`gaming-b` / `gaming-c` / `gaming-a`** — opt-in gaming shards (`:31358` / `:31351` / `:31352`)
- **`apps`** — remaining apps only (CPU, no pool shard)

### Host lifecycle status (May 2026)

Per-host operational status using a four-stage vocabulary. Use this section
as the source of truth when answering "is host X ready for production
traffic?" Update the table when a host transitions between stages.

| Stage | Definition |
|-------|------------|
| **Planned** | Design only; no bring-up attempted. Awaits hardware, scheduling, or upstream dependencies. |
| **Building** | Bring-up actively in progress. Not yet operational; do not route production traffic. |
| **Beta** | Operationally built and serving traffic, with documented partial-cluster limitations. Historical Petals expected-errors: [history/](history/). |
| **GA** | All aliases reliable, no partial-cluster caveats, no expected-error flags. Promotion criterion: every LiteLLM health-check cycle shows zero unhealthy deployments owned by this host. |

| Host | Stage | Since | Notes |
|------|-------|-------|-------|
| `hub` hub / brain + inference | **GA** | 2026-07-09 | Brain + CPU coordinator `:31360`; **RTX 3050** pool shard `:31353` |
| `apps` Ubuntu / remaining apps | **GA** | 2026-06-07 | CPU-only apps; **not** Petals bootstrap |
| `orchestrator` WOLF1 / Dockge + inference shard `:31350` | **GA** | 2026-06-07 | WSL Docker Engine; orchestrator host. Petals gateway retired. |
| `gaming-a` gaming-worker-a / opt-in shard `:31352` | **GA** | — | Gaming opt-in; **Petals retired** |
| `gaming-b` gaming-worker-b / inference opt-in shard `:31358` + train | **GA** | — | inference opt-in; blocked while `alfa-train.lock` |
| `gaming-c` gaming-worker-c / inference opt-in shard `:31351` + train | **GA** | — | inference opt-in; RAG is **`rag`**, not `gaming-c` |
| `rag` VM110 / RAG | **GA** | 2026-07-18 | Embed `:11435` + rerank `:8360` |
| `pool-opt-in` VM100 / opt-in shard `:31354` | **GA** | — | Shard only; RAG is **`rag`** |
| `secondary` gpu-248 / opt-in shard `:31355` | **GA** | — | Opt-in at start |
| `inference` ai-148 / 27B pool shards + hub | **GA** | 2026-06-28 | **48 GiB RAM** upgrade (was 16 GiB). i7-9700K / RTX 5060 + RTX 3060; NVIDIA **595.71.05**; shards `:31356`/`:31357`; coordinator on **`hub`** |

### VRAM accounting (April 2026 — Petals historical)

> **Not live.** Petals swarm totals below are audit history only. Live inference
> VRAM is the summary table + [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md).

| Pool | Nodes | VRAM |
|------|-------|------|
| Petals swarm | `apps` + `hub` + `orchestrator` (1× GPU since 2026-06-21) + `secondary` + `gaming-b` + `gaming-c` + `gaming-a` | **76 GB** (6+8+24+6+12+12+8) — *pending recompute to ~64 GB* |
| Ollama CPU chat — quality (`gaming-c`) | i7-12700 + DDR4 (no VRAM) | dense **`qwen3.5:27b`** ~19 GB (June 2026); `hub` runs no chat LLM |
| Ollama CPU chat — speed (`orchestrator`) | 7900X + DDR5 (6400 kit @ 4800, EXPO off; no VRAM) | **`qwen3.6:35b-a3b`** MoE ~22 GB, ~3B active (June 2026) |
| CPU pool (`gaming-c` + `orchestrator`) | No VRAM — CPU only | `gaming-c` **`qwen3.5:27b`** (quality), `orchestrator` **`qwen3.6:35b-a3b`** (speed). `gaming-b` runs reranker `Qwen3-Reranker-0.6B` (~0.6 GB) + embed standby. `hub` runs **no Ollama** (removed 2026-07-05; `operator_internal` routes to the RPC pool). |
| Total cluster GPU | **7** hosts / **8** Petals-capable GPUs | **76 GB VRAM** in the Petals pool |

> **Historical from here through Bootstrap order.** Live inference is Qwen3.6-27B
> on `hub:31360`. Live RAG is `rag`. Do not start Petals, 70B NF4, or Ollama
> CPU chat on `gaming-c` / `orchestrator`.

**Target frontier-chat (tier 3a, retired):** `meta-llama/Llama-3.3-70B-Instruct` (NF4) on Petals — **not** Qwen3 on Petals (see [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md)).
~55 GB weights + KV cache. Fits the **76 GB** swarm with comfortable
headroom. See [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md) for the tier
matrix and migration details.

**Target frontier-code (tier 3b):** **`Qwen3-Coder-Next-80B-A3B-Instruct` Q4_K_M**
on **llama.cpp RPC** — coordinator + **all** swarm **GPUs** as **`rpc-server`**
shards (**GPU** path; **not** CPU Ollama). **Retired:** **30B-A3B** GGUF on RPC.
Runbook: [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md).

**Target tiers 0/1/2 (CPU — two-host pool, June 2026 operator-selected):**

**Two-host CPU chat pool** — `gaming-c` quality + `orchestrator` speed; the April four-host 30B
MoE fleet and the May `gaming-c`-only `qwen3:32b` plan are **superseded**. Requires
**Ollama `0.30.x`** (Gated-DeltaNet) — verify tags load before cutover. GPU tiers unchanged.

| Host | CPU role | Model | Notes |
|------|----------|-------|-------|
| **`gaming-c` gaming-worker-c** | **CPU chat — quality (default) + primary embed** | **`qwen3.5:27b`** Q5 + `qwen3-embedding:4b` | 64 GB RAM; ~2–6 tok/s; quality aliases (`chat`/`agent`/`code`/`public-chat`/`app-chat`) |
| **`orchestrator` hub** | **CPU chat — speed** | **`qwen3.6:35b-a3b`** MoE Q4 (~3B active) | 32 GB DDR5-6400; ~18–30 tok/s; speed aliases (`fast`/`inline`/`autocomplete`) |
| **`hub` hub** | **No Ollama** (removed 2026-07-05) | — | `operator_internal` alias routes to the RPC pool (`LLAMACPP_35B_URL`/`LLAMACPP_CODE27_URL`); no sub-frontier chat |
| **`orchestrator` hub** | **No chat LLM** (gateway + GPU) | — | Stop Ollama after `gaming-c` cutover |
| **`gaming-b` gaming-worker-b** | **Reranker** + embed cold-standby | `Qwen3-Reranker-0.6B` (sidecar) + `qwen3-embedding:4b` (stopped) | Wired when RAG lands |

**Fallback when `gaming-c` down:** `frontier` (70B Petals) — no MoE fallback.

**Rollout:** `gaming-c` first → `gaming-b` → `hub` LiteLLM cutover → `orchestrator` last.

Vendor accuracy rationale: dense **32B** beats **30B-A3B MoE** on Creative Writing v3 and
LiveCodeBench v5 (non-thinking); IFEval ~tie — [MODEL_FIT_AUDIT.md](MODEL_FIT_AUDIT.md).
Hard coding targets tier **3b** `frontier-code` (80B RPC), not CPU.

**Bootstrap order:** `apps` remains the Petals DHT bootstrap (empty
`PETALS_INITIAL_PEERS`) — the bootstrap role is CPU/network-bound, not GPU,
so the smaller 1660S is fine for it. Every other Petals worker (`hub / orchestrator
/ gaming-b / gaming-c / gaming-a`) points at `apps`'s multiaddr. **`hub` Petals is retired**
(historical announce `orchestrator` -- do not use). The llama.cpp RPC
coordinator on `gaming-b` dials its three rpc-server backends directly — no
DHT; see [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) § "llama.cpp RPC ports".

## Per-node detail

> **Mixed archive.** Hardware and `br1` network notes may still be useful.
> Service lists that mention Petals gateways, Petals workers, embed-on-`gaming-c`,
> coordinator-on-gaming-worker-b, or `hub` RTX 5060 are **not live**. Live roles:
> summary table + Cluster roles above.

**hub REST automation (audit TN-002 / backlog #41):** May 2026 grep of `scripts/` and `deploy/cluster-members/hub/` found **no** `hub-cli`, `/api/v2.0/`, or `RestClient` usage — migrate here first if future automation talks to hub APIs (prefer JSON-RPC over WebSocket per vendor docs).

### `hub` — hub Scale 25.04 (brain + agent + hub)

- **Hostname:** hub
- **Operator capture (2026-04-18, GPU superseded):** historical **RTX 3060**
  capture; **current operator list:** **RTX 5060 8 GB** (Blackwell, cc **12.0**),
  **docker-compose.worker.blackwell.yml**, `nvidia-smi` to confirm. Bare-metal:
  **7900X**, **46** GiB visible RAM, AsrockRack **B650D4U-2L2T/BCM**, same storage
  layout per `lsblk` in [Operator hardware captures](#operator-hardware-captures).
- **OS:** hub Scale 25.04 ("Fangtooth") — Docker-native (no K3s). **Verify after upgrades:** run `hub-cli system version` on the host and reconcile this line (audit TN-001 / backlog #42).
- **CPU:** AMD Ryzen 9 7900X — 12 cores / 24 threads, Zen4, AVX-512
- **Motherboard (Apr 2026):** AsrockRack **B650D4U-2L2T/BCM** (`hostnamectl`).
- **RAM:** **~46 GiB** visible (`free -h`, Apr 2026); DDR5-5200 (~83 GB/s memory
  bandwidth — important for CPU-spill inference)
- **GPU 0:** NVIDIA **RTX 5060, 8 GiB VRAM** — **Blackwell** (cc 12.0) — use
  **Blackwell** Petals image (same class as **`gaming-c` / `gaming-b` / `gaming-a`** workers).
  Re-run `nvidia-smi` when the card is installed.
- **Network (2026-09-04 SSoT):** **`br1` is the LAN** ([hub_111_10G_NIC.md](hub_111_10G_NIC.md)):
  - `hub` -- **mgmt / API / LiteLLM / registry mirror / SMB / Dockge** on **`br1`** `/24`
  - `orchestrator` -- **NFS bind VIP** on **`br1`** `/32` (same L2 as `hub`, not a separate wire)
  - `orchestrator` -- **retired** (Petals); do not use for new traffic
  - `orchestrator` -- **retired**
  - **Do not** assign IPv4 to `br1` members (`enp6s0`, `enp7s0`, BCM ports, USB)
  - **Jun 2026 `iperf3` (same-L2 / `br1`):** ~937-948 Mbit/s from `apps`. Details:
    [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md).
- **Storage:**
  - Samsung 990 (600 GB free) → `/mnt/nvme` (new ZFS pool — see [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md))
  - `HDDs` pool → `/mnt/HDDs/Alfa-AI` (canonical shared storage tree)
- **Services:**
  - `alfa-ai-api` (FastAPI) — port 8420 (host), 8000 (container)
  - `alfa-ai-litellm` — port 4000
  - `alfa-ai-petals-gateway` — **fallback** instance (April 2026 rebalance:
    primary moved to `orchestrator`, last-resort on `apps`)
  - `alfa-ai-nginx` — reverse proxy
  - **No chat LLM** — 30B MoE retired. All sub-frontier aliases route to `gaming-c`.
    Embeddings on `gaming-c` gaming-worker-c (`EMBED_BASE_URL`).
  - **Petals worker** -- on the **RTX 5060 8 GB** (Blackwell), **paused/retired**;
    historical announce was `.157` (do not use).
  - NFS / SMB / registry mirror (`:5000`) -- bind NFS server on `storage` VIP on **`br1`**.
  - Dockge — hub Apps install at `:31014`
- **NOT running:** Postgres, Redis, VMs, websites/bots.

### `apps` — Ubuntu apps host (Proxmox VM 105 on `pve-i5.home`/`hypervisor`)

- **Hostname:** web-sites (guest); **VMID 105 `UBUNTU-PRO-WEBSITES`** on Proxmox
  host **`pve-i5.home` = `orchestrator`** (was `pvei7` before 2026-06-22
  reinstall).
- **Operator capture (2026-06-22):** [Operator hardware captures](#operator-hardware-captures)
  — authoritative `pve-i5.home` + VM 105 record (i5-9600K host, 5 vCPU / 32 GB
  guest, GTX 1660 Super passthrough, 500 GB disk on NVMe). The 2026-04-18
  capture (i7-6700K / 8 vCPU / 53 GiB) is **superseded**.
- **OS:** Ubuntu **26.04.1 LTS** (in-place from 24.04 on 2026-08-28; running
  kernel **7.0.0-30-generic**). First 26.04 reboot hit emergency mode because
  `/etc/fstab` had two `/mnt/cluster` NFS lines (`storage` and `hub`); live
  cluster is **`hub` only**. `storage` The_Biz mounts stay commented while
  `orchestrator` does not answer.
- **CPU:** **5 vCPU** (`cpu: host`) on the host's Intel **i5-9600K** (6c/6t,
  Coffee Lake). The April i7-6700K reading reflects the **prior** host.
- **RAM:** **32 GB** pinned (`balloon: 0` — GPU passthrough fixes guest RAM); was
  24 GB before the host's 2026-06-21 RAM upgrade to 64 GB.
- **Disk:** **500 GB** on the host's **`nvme`** pool (Samsung 990 PRO 1 TB),
  moved off the failing/degraded `rpool` SATA stripe on 2026-06-21.
- **GPU 0:** NVIDIA **GTX 1660 Super, 6144 MiB VRAM** (TU116) via PCI
  passthrough from `pve-i5.home` (`01:00.0`), CUDA compute capability 7.5 — driver
  **590.48.01** / CUDA **13.1** at the April capture
- **Services:**
  - Petals worker — GTX 1660 Super 6 GB, **DHT bootstrap** for the swarm.
    With only ~3 GB usable after the worker's activation/KV overhead, this
    node hosts **~2–3 blocks** of Llama-3.3-70B NF4. The bootstrap role
    itself is not GPU-bound — DHT discovery is CPU/network-bound — so the
    reduced block count is the only cost of having the smaller GPU here.
    **Not in the llama.cpp RPC stack** (6 GB is too tight for a useful
    Qwen3-Coder shard after the coordinator protocol overhead).
  - `alfa-ai-petals-gateway` — **last-resort** (April 2026 rebalance:
    primary on `orchestrator`, fallback in-stack on `hub`, this one is the
    fault-domain hedge)
  - Postgres — `alfa-ai` main DB (moved off `hub` to relieve RAM pressure)
  - Redis — session + queue store
  - All websites + bots: rankings-bot, atems, USPBF, alfaqd-website,
    contracts-bot, credit-check-bot, market-pie5-bot, rv-auto-finder
  - libvirt/KVM VMs (operator-configured)
  - Dockge agent — `:5001`

### `orchestrator` — Win11 (Dockge UI + Petals worker + CPU fleet speed tier)

- **Hostname:** **WOLF1** (was `hub-93`; updated 2026-06-21 capture)
- **Platform (2026-06-21 live capture):** **Ryzen 9 7900X** (12C/24T, Zen 4) —
  **ASUS ROG Strix X870E-E** Gaming **WiFi** (BIOS AMI **1203**, 2025-03-03),
  **2×16 GB** Corsair **`CMH32GX5M2B6400C36`** (6400-rated kit) running at
  **4800 MT/s** — **EXPO not enabled**, effective **DDR5-4800**, **~31.1 GiB**
  total. Replaces the old **i5-9600K** / **B365M** + DDR4 build; that hardware
  was later moved to **`secondary`**.
- **OS:** Windows 11 Pro for Workstations (build **10.0.26200**) — **WSL Docker
  Engine** (migrated 2026-06-07; see [WINDOWS_WSL_ROLLOUT_CHECKLIST.md](WINDOWS_WSL_ROLLOUT_CHECKLIST.md))
- **GPU 0:** **1×** NVIDIA **RTX 3060 12 GB** (Ampere, cc **8.6**) — **WDDM**,
  driver **610.62**, PCI `01:00.0`. **Single** Petals worker. **CUDA 12.4**
  `docker-compose.worker.yml`. In tier **3b** mode, **one** `rpc-server` on the
  3060. **The 2nd RTX 3060 was removed (2026-06-21)** — prior 2× / 24 GB docs
  superseded. (The 7900X also exposes an integrated **AMD Radeon** iGPU, not used
  for compute.)
- **Storage:** Samsung **870 EVO 1TB** SATA (`C:`) + Samsung **990 EVO Plus 1TB**
  NVMe (`D:`).
- **Services:**
  - Primary Dockge UI at `http://127.0.0.1:5002/` — registers every other
    node (`hub`, `apps`, `gaming-b`, `gaming-c`, `gaming-a`) as remote agents.
  - **1×** Petals worker (standard CUDA 12.4) on the **RTX 3060**.
  - **llama.cpp `rpc-server` ×1** — tier **3b** **`Qwen3-Coder-Next-80B-A3B`** shard
    on the **3060** (**mutually exclusive** with Petals on that GPU). See [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md).
  - **No chat LLM** — 30B MoE retired. All sub-frontier aliases route to `gaming-c`.
- **Deploy:** `deploy/cluster-members/orchestrator/deploy.ps1`.

### `gaming-b` — gaming-worker-b (Blackwell Petals worker + CPU fleet fallback + llama.cpp coordinator)

- **Hostname:** gaming-worker-b
- **OS:** Windows 11 + **WSL Docker Engine** (migrate before deploy — [WINDOWS_WSL_ROLLOUT_CHECKLIST.md](WINDOWS_WSL_ROLLOUT_CHECKLIST.md))
- **Motherboard:** **ASRock Z590**
- **CPU:** Intel **i7-11700** — 8 cores / 16 threads, Rocket Lake
- **RAM:** 64 GB DDR4-3200
- **GPU 0:** NVIDIA RTX 5070, 12 GB VRAM, Blackwell (cc 12.0)
- **Services:**
  - Petals worker (CUDA 12.8 Blackwell variant).
  - **Embedding cold-standby** — Ollama with `qwen3-embedding:4b` installed
    but service **stopped**; only started during a `gaming-c` outage. See
    [deploy/cluster-members/gaming-worker-b/ollama-embed-standby.md](../deploy/cluster-members/gaming-worker-b/ollama-embed-standby.md).
  - **llama.cpp `llama-server` coordinator on `:31360`** — tier 3b
    `frontier-code` (**80B**), dials **all** `rpc-server` backends. See
    [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md).
  - **CPU reranker (planned, June 2026)** — **`Qwen3-Reranker-0.6B`** via a
    TEI/Infinity/llama.cpp **sidecar** (~0.6 GB, **not** Ollama). No chat LLM. See
    [deploy/cluster-members/gaming-worker-b/README.md](../deploy/cluster-members/gaming-worker-b/README.md)
    § CPU reranker plan.
- **Deploy:** `deploy/cluster-members/gaming-worker-b/deploy.ps1` (SMB staged from `orchestrator`).
  Uses `docker-compose.worker.blackwell.yml` (Petals, CUDA 12.8) plus the
  llama.cpp RPC compose files under `deploy/llamacpp-rpc/`.

### `gaming-c` — gaming-worker-c (Blackwell Petals worker + llama.cpp RPC backend + primary embed host + CPU quality chat)

- **Hostname:** gaming-worker-c
- **OS:** Windows 11 + **WSL Docker Engine** (migrate before deploy — [WINDOWS_WSL_ROLLOUT_CHECKLIST.md](WINDOWS_WSL_ROLLOUT_CHECKLIST.md))
- **Motherboard:** **ASUS Z690**
- **CPU:** Intel i7-12700 — 12 cores / 20 threads, Alder Lake
- **RAM:** 64 GB
- **GPU 0:** NVIDIA RTX 5070, 12 GB VRAM, Blackwell (cc 12.0) — **Apr 2026**
  upgrade (replaces **5060 8 GB**).
- **Services:**
  - Petals worker (CUDA 12.8 Blackwell variant).
  - **llama.cpp `rpc-server`** — tier **3b** shard (**80B**).
  - **Primary embedding host** — Ollama serving `qwen3-embedding:4b` on
    `:11434` (`EMBED_BASE_URL=http://orchestrator` on `hub`).
    `gaming-b` is cold-standby. **Re-embed corpora on switch from `nomic-embed-text`.**
  - **CPU quality chat LLM (June 2026)** — dense **`qwen3.5:27b`** (~19 GB Q5).
    Quality aliases (`chat`/`agent`/`code`/`public-chat`/`app-chat`) route here;
    `orchestrator` `qwen3.6:35b-a3b` serves the speed aliases. Each falls back to the other, then `frontier`.
    See [deploy/cluster-members/gaming-worker-c/README.md](../deploy/cluster-members/gaming-worker-c/README.md)
    § CPU model plan.
- **Deploy:** `deploy/cluster-members/gaming-worker-c/deploy.ps1`.

### `gaming-a` — gaming-worker-a (Blackwell inference RPC shard + Dockge worker)

Hardware capture **2026-07-14** (`nvidia-smi`, `wmic` on live host). Prometheus instance: **`gaming-worker-a-219`**.

- **Windows hostname:** `DESKTOP-7EOGC3R` (cluster label `gaming-worker-a-219`)
- **OS:** Windows 10 Pro **22H2** (build **19045**) + **WSL2 Ubuntu** (Docker Engine **29.5.3**)
- **Motherboard:** Gigabyte **Z390 GAMING X-CF**, BIOS **F9** (2019-10-15)
- **CPU:** Intel Core **i5-9600K** @ 3.70 GHz — **6c/6t**, Coffee Lake (package temp via OhmGraphite ~42 C idle)
- **RAM:** **64 GB** DDR4 (`wmic` **63.9 GiB** usable)
- **GPU 0:** NVIDIA **GeForce RTX 5060**, **8151 MiB** VRAM, Blackwell (compute **12.0**), driver/KMD **610.74**, CUDA UMD **13.3**
  - PCIe: host max **Gen3**, GPU max **Gen5**, link **Gen3 ×8** (`00000000:01:00.0`)
  - Power limit **145 W** (default); idle ~27 W
  - UUID: `GPU-1b7f6522-826c-f34c-4b61-9ee3683e786f`
- **Storage:** **Samsung SSD 870 EVO 500 GB** (`D:` ~465 GiB) + **Crucial P3 Plus 1 TB** (`C:` ~931 GiB); **~165 GiB** free on C:, **~142 GiB** on D: (2026-07-14)
- **Network:** Intel **I219-V** **1 GbE** (`18-C0-4D-43-56-13`); WSL **vEthernet** virtual NIC
- **Monitoring (`monitor`):** `windows_exporter` **:9182**, `nvidia_gpu_exporter` **:9835**, OhmGraphite **:4445** (CPU via PawnIO), Dozzle agent **:7007**
- **Services (today):**
  - **Dockge agent** `:5003` (Win10 portproxy; not `:5001` — GT3 mobile conflict)
  - **Optional inference `rpc-server`** shard **`:31352`** (8 GB tensor slice; orchestrator deploy when gaming idle)
  - **Petals retired** — do not start `petals-worker`
- **Deploy:** `deploy/cluster-members/gaming-worker-a/deploy.ps1`; inference: `deploy-grev27-pool-shard.ps1`

## Model stack (live)

LiteLLM on `hub:8413` (container `:4000`). Aliases: [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md),
[GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md).

| Alias | Model | Runtime / host |
|-------|-------|----------------|
| **`frontier-code`** (production default) | Qwen3.6-27B Q8_0 | llama.cpp RPC coordinator **`hub:31360`** |
| **`frontier`** | Same 27B pool today | Reserved for a future exclusive ~70–72B Q4 on the full mesh |
| Compat (`fast` / `chat` / …) | Remap to the 27B pool | 35B MoE and Petals 70B are **retired** |

| Purpose | Model | Host |
|---------|-------|------|
| Embeddings | production RAG embed | **`rag:11435`** |
| Reranker | production RAG rerank | **`rag:8360`** |

June 2026 CPU-chat / Petals 70B / 80B-on-gaming-worker-b rows that used to sit here are
**historical** (same as VRAM accounting above). Do not move the brain to `orchestrator`.

## Petals swarm — workers (port **31330** TCP) — RETIRED

> **Do not deploy.** Do not open `31330/tcp` for Petals. Do not set
> `PETALS_INITIAL_PEERS`. Archive only — live inference is inference above.

All workers run `deploy/petals/docker-compose.worker.yml` (standard CUDA 12.4)
or `docker-compose.worker.blackwell.yml` (CUDA 12.8) with the **same**
`PETALS_MODEL` as every other worker in the swarm. Docker path:
`docker compose ... build` then `up -d`.

**Bootstrap (first worker) = `apps`**. Leave `PETALS_INITIAL_PEERS` empty on
`apps`. Every other worker sets `PETALS_INITIAL_PEERS` to the `apps` multiaddr
from `sudo docker logs petals-worker | grep "Running a server on"` (the peer-id
changes after every worker restart — refresh it whenever `apps` bounces).

| Node | LAN IP | GPU | Blocks (Llama-3.3-70B NF4, operator estimate) | Peer address example |
|------|--------|-----|----------------------------------|----------------------|
| **Bootstrap: `apps`** | `apps` | **GTX 1660 Super 6 GB** (post-swap) | ~2–3 | `/ip4/apps/tcp/31330/p2p/<peer-id>` |
| `hub` hub | `hub` (mgmt) | **RTX 5060 8 GB** (Blackwell) | ~9-10 | Blackwell compose; Petals **retired** |
| `orchestrator` | `orchestrator` | RTX 3060 12 GB (single GPU; 2nd removed 2026-06-21) | ~14–15 | standard CUDA 12.4 |
| `inference` ai-148 | `orchestrator` | **RTX 5060 8 GB** + **RTX 3060 LHR 12 GB** | ~9–10 + ~14–15 | standard CUDA 12.4 |
| `gaming-b` gaming-worker-b | `orchestrator` | RTX 5070 12 GB (Blackwell) | ~14–15 | Blackwell compose |
| `gaming-c` gaming-worker-c | `orchestrator` | RTX 5070 12 GB (Blackwell) | ~14–15 | Blackwell compose |
| `gaming-a` gaming-worker-a | `orchestrator` | RTX 5060 8 GB (Blackwell) | ~9–10 | Blackwell compose |

**Total (operator list):** **76 GB** across **7** hosts / **8** GPUs. **Llama-3.3-70B**
NF4 (Petals) fits with headroom for KV cache (confirm with live `nvidia-smi`). See
[ROADMAP.md](ROADMAP.md) "Cluster rebalance" for the full rationale.

**Firewall:** allow 31330/tcp between each worker and the `apps` gateway host.

## Template files

- Field reference (all workers): [deploy/petals/env.worker.example](../deploy/petals/env.worker.example).
- **Per-host templates** (copy into the live `.env*` on each machine — see [docs/petals/PER_HOST_ENV_TEMPLATES.md](petals/PER_HOST_ENV_TEMPLATES.md)):
  `deploy/cluster-members/<member>/env.worker.example`, plus brain `deploy/env.example`,
  apps `apps-105/env.apps.example`, and gateway `operator-93/env.gateway.example`.
- Env templates: `deploy/cluster-members/<host>/env.worker.example` (canonical). See [petals/PER_HOST_ENV_TEMPLATES.md](petals/PER_HOST_ENV_TEMPLATES.md).

## Deployment pipeline

All code flows through GitHub (`operator@example.com:example/alfa-ai.git`).
Artifacts flow through hub/hub (`hub`) via NFS (Linux) and SMB
(Windows). `orchestrator` stages per-member deploy bundles into
`\\hub\temp\cluster_members\`.

| Node | Source | Artifacts | Deploy command | Member folder |
|------|--------|-----------|----------------|---------------|
| `hub` (hub, **brain + Petals worker + hub**; no chat LLM) | `/mnt/HDDs/Alfa-AI/repo/alfa-ai` | Local NFS + SMB + registry mirror + SSD Petals pool (sdj+sdk mirror) | `deploy/cluster-members/hub/deploy.sh` | `hub-111/` |
| `apps` (apps + Petals worker) | `/home/operator/alfa-ai` | NFS `/mnt/cluster` (from `hub`) | `deploy/cluster-members/apps/deploy.sh` | `apps-105/` |
| `orchestrator` (primary Dockge + Petals worker) | `C:/Users/operator\alfa-ai` (git pull) | SMB `\\hub\temp\` | `deploy/cluster-members/orchestrator/deploy.ps1` | `operator-93/` |
| `gaming-b` gaming-worker-b | SMB `\\hub\temp\cluster_members\gaming-worker-b-249\` | Same SMB | `deploy.ps1` | `gaming-worker-b-249/` |
| `gaming-c` gaming-worker-c | SMB `\\hub\temp\cluster_members\gaming-worker-c-59\` | Same SMB | `deploy.ps1` | `gaming-worker-c-59/` |
| `gaming-a` gaming-worker-a | SMB `\\hub\temp\cluster_members\gaming-worker-a-219\` | Same SMB | `deploy.ps1` | `gaming-worker-a-219/` |
| `inference` ai-148 | `~/alfa-ai` (git pull) | NFS `/mnt/cluster` (from `hub`) | `deploy/cluster-members/inference-coordinator/deploy.sh` | `ai-148/` |

Full workflow: [SOURCE_OF_TRUTH_AND_SYNC.md](SOURCE_OF_TRUTH_AND_SYNC.md).

## Related docs

- [history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md) — step-by-step migration from `apps` to `hub`
- [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) — new brain operator guide
- [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md) — apps-host operator guide
- [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md) — NVMe hot pool setup
- [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) — HDDs shared storage tree
- [petals/WORKER_ROLLOUT.md](petals/WORKER_ROLLOUT.md) — worker bring-up phases
- [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md) — Petals/Ollama/LiteLLM architecture
- [ROADMAP.md](ROADMAP.md) — near-term cluster work
- [SOURCE_OF_TRUTH_AND_SYNC.md](SOURCE_OF_TRUTH_AND_SYNC.md) — code + artifact flow
