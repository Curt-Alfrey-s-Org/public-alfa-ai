# Cluster LAN audit - IP assignments and iperf

Operator reference for **every cluster LAN IP**, how the OS picks a "primary" address, dual-NIC rules, conflict checks, and throughput baselines.

**alfa-ai inference loop (inference + RAG):** `orchestrator`, `pool-opt-in` (shard only), `inference`, `hub`. **Not** `apps` for embed, RPC, or coordinator traffic. `apps` is apps/repo farm (contracts-bot, rankings, postgres).

**Embed + rerank (production):** **`inference:11435`** / **`inference:8360`** per [`deploy/cluster-members/_common/rag-sidecars.env`](../deploy/cluster-members/_common/rag-sidecars.env). Legacy `pool-opt-in` embed ports are stopped on cluster start.

## Host max network I/O (quick reference)

**Best measured hub path (pre-move):** `inference` (LACP `802.3ad`) → hub NFS **`storage`** = **1.83 Gbps** (`iperf3 -P 4`, 2026-07-13). That is the high number on the `hub` box — `storage` is an alias on the same hub `br1` / BCM fabric as `hub`.

**Cabinet move (2026-07-27):** new physical cabling -- [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md). From `orchestrator`: `hub` OK; `storage`/`inference`/`hypervisor`/`secondary` not yet reachable. Re-baseline iperf after hub bridge + ping green.

| Host | Role | Link / NIC (live class) | Best measured TCP (iperf3) | Ceiling notes |
|------|------|-------------------------|----------------------------|---------------|
| **`hub` / `storage`** | hub hub (brain, NFS, SMB, registry) | **`br1`** (BCM + i210 + USB members; live 2026-09-04) | **~946 Mbps** single-stream from `apps`; **1.83 Gbps** multi-flow **from `inference` to `storage`** (same-L2 / `br1`) | Hardware can do 10G; **aggregate** wins when peer has LACP. Keep **`hub/24` + `storage/32` on `br1` only** ([br1 src bug](#known-lan-issues-2026-07-03-session)). |
| **`inference`** | inference shards + CPU RAG | `bond0` **802.3ad** (eno1 + USB), 1G per leg | **~946 Mbps** `-P 1`; **~1.83 Gbps** `-P 4` to `storage` | Best **client** for hub seed/NFS. Live mode confirmed 2026-07-16 (`bonding/mode=802.3ad`). |
| **`orchestrator`** | Orchestrator + RPC `:31350` | ~1 GbE path (Realtek / WSL mirror) | **~947 Mbps** | X540 10G NICs present but **uncabled** — spare capacity. |
| **`pool-opt-in`** | VM100 RPC shard `:31354` | virtio on Proxmox | **~22 Gbps** same-hypervisor; **~365–940 Mbps** cross-host | High Gbps = local virtio, **not** LAN to hub. |
| **`apps`** | Apps / iperf vantage | ~1 GbE `bond0` | **~923–947 Mbps** to peers; ~36 Gbps loopback | Survey client only — **not** embed/RPC path. |
| **`gaming-a`** | Gaming / opt-in RPC | **1 GbE** (downstream of 2.5G switch) | _measure when online_ | See [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md) gaming chain |
| **`gaming-c` / `gaming-b`** | Gaming / opt-in RPC | **2.5 GbE** (shared 2.5G switch → 10G uplink) | _not measured_ | `gaming-c` shard `:31351`, `gaming-b` `:31358` |
| **`hypervisor`** | Proxmox | dual bridge | _not measured_ | Infra host. |

**How to read the numbers**

1. **~940–950 Mbps** = healthy single TCP stream on a **1 GbE** path (normal for `orchestrator`/`apps`/`hub` peers).
2. **~1.8 Gbps** = **LACP multi-flow** (`inference` → hub). Re-check with `IPERF3_PARALLEL=4` from `inference` after cabling changes.
3. **Tens of Gbps** on `pool-opt-in`/`apps` same-VM = **virtio/loopback**, ignore for hub planning.
4. **Link Speed: 10000 Mb/s** on `hub` BCM ([hub_111_10G_NIC.md](hub_111_10G_NIC.md)) is **PHY** capacity; iperf still shows ~1G until the **other end** is also multi-gig or LACP-aggregated.

Full dated matrices below; utilization narrative: [LAN_BANDWIDTH_UTILIZATION.md](LAN_BANDWIDTH_UTILIZATION.md).

**Run iperf matrix (from any Linux peer with `iperf3` client):**

```bash
# On each target host first:
bash scripts/iperf3-bootstrap.sh

# Production paths (default): orchestrator, pool-opt-in, hub, storage, inference
bash scripts/cluster-lan-iperf-matrix.sh <client-label>

# LACP / multi-flow check (inference client):
IPERF3_PARALLEL=4 bash scripts/cluster-lan-iperf-matrix.sh 148-lacp

# Label results when inference / bots are still running:
LOAD_NOTE="inference+contracts+rankings up" bash scripts/cluster-lan-iperf-matrix.sh 105-mgmt-under-load
# or: bash scripts/cluster-lan-iperf-matrix.sh --under-load 105-mgmt-under-load
```

**Vantage hosts:** `apps` and `inference` are common **iperf clients** for LAN surveys. Running the matrix **from** `apps` does **not** mean `apps` is in the embed/RPC data path.

Windows workers (`orchestrator`): use WSL for server bootstrap - `wsl -d Ubuntu bash scripts/iperf3-bootstrap.sh`. WSL may not ship `iperf3` client; run the matrix from `apps` or `inference`, or install `iperf3` in WSL first.

Official throughput testing: [iperf3](https://software.es.net/iperf/). Proxmox bridge policy: [Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration) - do **not** attach guests to **both** `vmbr0` and `vmbr1` on the same `/24`; use **bond (LACP) -> one bridge** for more bandwidth on one LAN.

---

## How the OS picks a “primary” IP (does it matter?)

Linux does **not** have one permanent “primary” IP. It chooses per packet:

| Decision | Rule |
|----------|------|
| **Outbound to LAN** | Source = IP on the interface used by the **route** (usually mgmt `apps` / `inference` via `bond0` default). |
| **Inbound** | Any IP configured on the host can receive if the service binds `0.0.0.0` or that specific alias. |
| **`hostname -I` first field** | Order of addresses in the kernel — **not** the mgmt IP. On VM105, `.104` often appears **before** `apps`. **Do not use `hostname -I` for cluster wiring.** |
| **Default route** | Defines “primary egress” — must be **mgmt NIC** (`bond0` → `apps` / `inference`). |

**VM105 “booted using .104”:** If Proxmox/cloud-init **displays** `.104` first or net1 comes up before bond0, that is cosmetic. What matters:

1. **inference orchestration / verify hub** uses `operator@orchestrator` (mgmt). `apps` remains apps host (postgres, bots).
2. **Default route** is `via orchestrator dev bond0` (verified 2026-07-03).
3. **Data IP `.104`** is `/32` on `enp6s19` with `from orchestrator lookup 101` — legacy embed data plane only; **retired** (RAG on `inference` since 2026-07-09).
4. Scripts that auto-detect IP (`hostname -I`, `iperf3-bootstrap` hint line) may show `.104` — always pass **explicit mgmt IPs** in cluster configs.

Same pattern on **`inference`**: `hostname -I` lists `.147` before `inference`; inference RPC and SSH use **`inference` only**.

**WOLF1 (`orchestrator`) WSL mirrored networking:** WSL Ubuntu also has a second LAN NIC **`.92`** (`eth3`, lower default-route metric than `eth2`/`orchestrator`). Orchestrator and cluster scripts target **`orchestrator`** (Windows host / primary mirror). `.92` is the same physical host — **not a duplicate-IP conflict** (one MAC `98:b7:85:21:1f:d7` in ARP). Do not wire cluster services to `.92`.

---

## Full LAN IP map (no conflicts on `/24`)

| IP | Host | NIC / role | Purpose | Cluster traffic |
|----|------|------------|---------|-----------------|
| **orchestrator** | WOLF1 WSL | `eth3` (mirrored) | Secondary LAN on `orchestrator` box | **Not used** for cluster wiring |
| **orchestrator** | `orchestrator` WOLF1 | mgmt (Win11 + WSL mirrored) | Orchestrator, Petals GW `:8413`, Dockge `:5002`, RPC shard `:31350` | **inference mgmt** |
| **orchestrator** | VM100 | mgmt `vmbr0` | inference shard `:31354` only (1660S) | **RPC shard** — not embed |
| **orchestrator** | VM105 | data `enp6s19` `/32` | Legacy embed data plane (Track A) | **Retired** — second virtio not present in 2026-07 guest dump |
| **apps** | VM105 | mgmt **`bond0`** (slave `enp6s18`) on Proxmox **`vmbr1`** | Apps, bots, Postgres (repo farm) | Live 2026-07-30: SSH OK; no `.104` NIC; see [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md) VM105 |
| **hub** | hub | mgmt on `br1` (`hub/24` primary) | Brain API, LiteLLM `:8413`, registry, SMB | **inference / brain mgmt** |
| **orchestrator** | hub | **`br1`** alias (`/32` NFS VIP) | NFS server bind; same L2 as `hub` | Mount `storage` or `hub`; max iperf **1.83 Gbps** from `inference` (same-L2 / `br1`) |
| **orchestrator** | hub | **Retired** (stale on `enp7s0` until removed) | -- | **Do not use** for new traffic |
| **orchestrator** | hub | retired | — | **Do not use** |
| **orchestrator** | `inference` | data USB NIC `/32` | **Retired** (2026-07-13 LACP) | Single IP `inference` on `bond0` only |
| **orchestrator** | `inference` ai-148 | LACP `bond0` (`eno1` + USB) | inference shards `:31356`/`:31357`, **CPU RAG** `:11435`/`:8360` | **inference + RAG** |
| **orchestrator** | gaming-worker-c | mgmt | Opportunistic Petals / embed | Optional |
| **orchestrator** | gaming-worker-a | mgmt | Opportunistic Petals / RPC | Optional (offline 2026-07-03) |
| **orchestrator** | gaming-worker-b | mgmt | Opportunistic / legacy coord | Optional |
| **orchestrator** | Proxmox | `vmbr0` / `nic0` | Hypervisor; VM100 on this bridge | Infra |
| **orchestrator** | Proxmox | `vmbr1` / `nic1` | Second uplink; apps VMs 102-107 | Infra |

**No duplicate IPs** on the LAN. Multiple addresses per host are **aliases/NICs**, not conflicts.

**inference RPC** (`31350`–`31360`): always **mgmt IPs** (`orchestrator`, `inference`, `hub`) — never `.104`/`.147`.

### Reachability ping sweep (from `apps`, 2026-07-03)

| IP | Status |
|----|--------|
| `orchestrator`, `pool-opt-in`, `.104`, `apps`, `hub`, `storage`, `.157`, `inference`, `.147`, `gaming-c`, `gaming-b`, `hypervisor` | UP |
| `gaming-a` | DOWN (host offline or powered off) |

### ARP uniqueness check (from `apps`)

All responding cluster IPs map to **distinct MAC addresses** (per host).

**hub `hub` / `storage` (2026-09-04):** both are **`br1`** addresses on the
same bridge MAC. Historical Jun 2026 text claimed `hub`/`storage`/`.157` share one
NIC MAC -- that reflected pre-bridge alias layout. Live **`br1` members** (no
IPv4): `enp6s0`, `enp7s0`, `enp11s0f0np0`, `enp11s0f1np1`, `enxc65a06c6ae7e`.
**Misconfig:** stale `storage/32` on `enp11s0f1np1` and `.157/32` on `enp7s0`
(Post Init) -- remove; IPv4 belongs on **`br1` only**.

`.104` is local to VM105 (`enp6s19`); `apps` uses `bond0`.

---

## Dual-NIC mandatory config (`.104`/`apps`, `.147`/`inference`)

Without source policy routing, two NICs on the same `/24` causes **ARP flux** and can break **all** LAN egress (inference verify, bots).

Required (see `PORT_ASSIGNMENTS.md`):

1. Data IP = **`/32`** (not `/24`).
2. `ip rule from <data-ip> lookup 101` + table 101 on-link route only.
3. `arp_ignore=1`, `arp_announce=2` in `/etc/sysctl.d/60-alfa-dual-nic.conf`.

**Verify on VM105 (2026-07-03, live):**

```
default via orchestrator dev bond0
ip rule: from orchestrator lookup 101
arp_ignore=1 arp_announce=2
ip route get hub from apps → dev bond0
ip route get hub from orchestrator → dev enp6s19 table 101
hostname -I first field: orchestrator  (cosmetic only)
```

Setup scripts: `deploy/cluster-members/apps/setup-dual-ip-data-plane.sh`, `deploy/cluster-members/inference-coordinator/setup-dual-ip-data-plane.sh`.

---

## iperf3 results — 2026-07-03 (client: `apps` → server `:5201`)

Servers: `iperf3-bootstrap.sh` on `orchestrator` WSL, `pool-opt-in`, `apps`, `inference`, `hub` (native).

| Target | IP | TCP | Throughput | Notes |
|--------|-----|-----|------------|-------|
| orchestrator mgmt | orchestrator | OK | **947 Mbps** | Nominal 1 GbE |
| pool-opt-in mgmt | orchestrator | OK | **~22 Gbps** | Same Proxmox host / virtio path |
| .104 data | orchestrator | OK | **~36 Gbps** | Same VM as client (loopback) |
| apps mgmt | apps | OK | **~36 Gbps** | Same VM loopback |
| hub mgmt | hub | OK | **946 Mbps** | 1 GbE |
| hub NFS | orchestrator | OK | **947 Mbps** | Same-L2 / `br1` as `hub` |
| hub Petals (retired) | orchestrator | OK | **947 Mbps** | Same-L2 / `br1`; **do not use** |
| inference mgmt | orchestrator | OK | **946 Mbps** | 1 GbE |
| .147 data | orchestrator | OK | **946 Mbps** | 1 GbE via `inference` USB NIC |
| gaming-c gaming-worker-c | orchestrator | — | — | Host up; no iperf server |
| gaming-a gaming-worker-a | orchestrator | — | — | Host down |
| gaming-b gaming-worker-b | orchestrator | — | — | Host up; no iperf server |
| hypervisor pve | orchestrator | — | — | Host up; no iperf server |

**Interpretation:** Cross-host 1 GbE paths (~940–950 Mbps) are healthy. High Gbps numbers on `.104`/`apps` are **local same-VM** tests, not cluster WAN speed.

**Optional:** bootstrap iperf on `gaming-c`/`gaming-b`/`hypervisor` and re-run matrix for gaming/infra hosts.

---

## iperf3 results — 2026-07-13 (under load)

**Load note:** inference + contracts-bot + rankings-bot running. These are **not** idle baselines. Single-stream (`-P 1`) from `apps` under load can show ~565 Mbps to `inference` while the same path at idle is ~922 Mbps — that gap is concurrent traffic, not broken LACP.

**Client `apps` (vantage only — not embed host), `-P 1`:**

| Target | IP | TCP | Throughput | Notes |
|--------|-----|-----|------------|-------|
| inference mgmt | orchestrator | OK | **922 Mbps** | Production RAG + inference host |
| storage NFS | orchestrator | OK | **923 Mbps** | Hub NFS bind |
| hub mgmt | hub | OK | **923 Mbps** | Brain / LiteLLM |
| orchestrator mgmt | orchestrator | OK | **923 Mbps** | Orchestrator / RPC shard |
| pool-opt-in mgmt | orchestrator | OK | **~365 Mbps** | **Not** embed path — VM100 is RPC shard only; lower Mbps under load |

**Client `inference` (LACP bond0), `-P 4`:**

| Target | IP | TCP | Throughput | Notes |
|--------|-----|-----|------------|-------|
| storage NFS | orchestrator | OK | **1.83 Gbps** | **Peak hub path** — multi-flow LACP (+93% vs ~946 Mbps 1G reference) |
| hub mgmt | hub | OK | **~941 Mbps** | Same hub box as `storage`; single-stream still ~1G from this client |
| apps mgmt | apps | OK | **~941 Mbps** | Apps vantage |

**Production paths to optimize:** `inference` <-> `storage`/`hub` (NFS + hub — **use `inference` as client for max seed speed**), `inference` <-> `orchestrator` (RPC). **Not** `apps` <-> `pool-opt-in` (no RAG traffic there).

For **idle** baselines and % improvement claims, follow [Idle baseline procedure](#idle-baseline-procedure) below.

---

## Idle baseline procedure

Run when you need clean throughput numbers (before claiming % improvement after LAN changes).

1. **Quiet inference** — from `orchestrator` (operator):
   ```powershell
   cd C:/Users/operator\alfa-ai
   powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 stop
   ```
2. **Apps** — leave contracts/rankings up **or** stop them; if left up, set `LOAD_NOTE` when running the matrix (partial idle).
3. **Bootstrap servers** on targets: `bash scripts/iperf3-bootstrap.sh` on each peer (or SSH per host).
4. **Run matrix** — prefer `inference` (LACP client) and optionally `apps` (apps vantage):
   ```bash
   bash scripts/cluster-lan-iperf-matrix.sh 148-idle
   bash scripts/cluster-lan-iperf-matrix.sh 105-idle
   ```
   Use `IPERF3_PARALLEL=1` (default) for 1 GbE single-flow; `IPERF3_PARALLEL=4` only for LACP / multi-flow checks from `inference`.
5. **Record** results in this doc (date, client label, `LOAD_NOTE` if any).

After idle iperf, run `Start-Stop-AlfaAi.ps1 start` when the cluster should be back up.

---

## Doc / config drift (embed) — corrected 2026-07-13

| Location | Was (stale) | Now (production) |
|----------|-------------|------------------|
| `rag-sidecars.env` | — | **`EMBED_HOST=orchestrator`**, **`RERANK_HOST=orchestrator`** |
| `PORT_ASSIGNMENTS.md` / older docs | embed `pool-opt-in:11435` | **`inference:11435`** (CPU RAG on ai-148) |
| Matrix `apps` -> `pool-opt-in` | mislabeled "embed path" | **Survey only** — embed is not on `pool-opt-in` or `apps` |
| `.104` data NIC on VM105 | Track A embed | **Retired** — policy routing kept; no new embed traffic |

`.104` and `.147` remain valid as **data-plane NIC** policy-routing tests only.

---

## Proxmox guest bridging — do not dual-home

Per [Proxmox Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration): bridges separate L2 domains. Attaching one guest to **both** `vmbr0` and `vmbr1` on the same `/24` causes ARP flux and dual-gateway confusion.

**Correct patterns:**

- **Current `hypervisor` split:** one virtio NIC per VM — VM100 on `vmbr0`, apps VMs on `vmbr1` ([hypervisor_NIC_MAX_USE.md](hypervisor_NIC_MAX_USE.md)).
- **More bandwidth on one LAN:** LACP bond of physical NICs into **one** bridge (as on `inference`), not dual-home per VM.

---

## Known LAN issues (2026-07-03 session)

| Symptom | Cause | Fix |
|---------|-------|-----|
| `orchestrator:31350` not reachable from `hub` | WSL mirrored firewall stale | `wsl --shutdown`, redeploy shard, Hyper-V firewall rules |
| `inference:31356` wedge | RPC accept queue | Staggered startup + `GGML_CUDA_DISABLE_GRAPHS=1`; full stop+start — [inference_RPC_RELIABILITY.md](inference_RPC_RELIABILITY.md) |
| Coordinator OK, inference dead | Split-brain after shard recycle | Redeploy coordinator with all shards; no mid-start redeploy |
| Post-start verify rerank fail | Rerank mandatory on `inference` | Both `:11435` + `:8360` on ai-148 required; check CPU type **host** (AVX2) if SIGILL |
| `hostname -I` shows `.104` first on VM105 | Kernel address order | Use explicit `apps` in SSH and orchestrator |
| Stale `/mnt/cluster` after hub save | `storage` unreachable or wrong src on `br1` | hub `br1`: **`hub/24` + `storage/32` only** (no IPv4 on members); remount + `preflight-nfs-hub.sh` + systemd watch |
| `hub` ping `inference` OK but TCP `No route to host` (SSH/RPC/verify fail) | Live `br1` applied **`storage/24` as primary** or member IPs broke routing; kernel `src orchestrator` | Set aliases **`hub/24` + `storage/32` on `br1` only** via `interface.update` / commit / checkin ([interface.update](https://api.hub.com/v25.10.0/api_methods_interface.update.html)); remove IPv4 from `br1` members (Post Init). Confirm `ip route get orchestrator` shows `src hub dev br1`. Live 2026-09-04: wrong `storage/32` on `enp11s0f1np1`, `.157/32` on `enp7s0`. |
| WSL matrix all ERR | `iperf3` client not installed in WSL | `sudo apt install iperf3` or run matrix from `apps` |

---

## Related

- [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) — ports + dual-NIC section
- [WINDOWS_WSL_DOCKER_ENGINE.md](WINDOWS_WSL_DOCKER_ENGINE.md) — `orchestrator` mirrored + firewall
- [LAN_OPERATOR_TROUBLESHOOTING.md](LAN_OPERATOR_TROUBLESHOOTING.md) — runtime failures
- `scripts/iperf3-bootstrap.sh` / `scripts/cluster-lan-iperf-matrix.sh`