# LAN bandwidth utilization (SSoT)

**Question:** Are we using 1 GbE (and spare NICs) for max effect, or are links mostly idle while hot paths contend?

**Verdict (2026-07-13 / updated 2026-07-16):** Cross-host 1 GbE paths still **saturate ~920-950 Mbps** on idle single-stream tests. **Peak measured:** `inference` LACP (`802.3ad`) multi-flow to hub **`storage` = 1.83 Gbps** — that is the high number on the `hub` hub. Under load (inference + bots), single-stream numbers can drop (e.g. `apps` -> `inference` ~565 Mbps) without indicating broken topology.

**Per-host ceiling table:** [CLUSTER_LAN_AUDIT.md — Host max network I/O](CLUSTER_LAN_AUDIT.md#host-max-network-io-quick-reference).

**alfa-ai production data paths:** `inference` <-> `storage` (NFS hub), `inference` <-> `hub` / `orchestrator` (RPC). **Not** `apps` <-> `pool-opt-in` — `apps` is apps vantage only; embed/rerank are **`inference:11435`/`:8360`** ([`rag-sidecars.env`](../deploy/cluster-members/_common/rag-sidecars.env)).

**Plan:** [.cursor/plans/LAN_1GBE_MAX_UTILIZATION.md](../.cursor/plans/LAN_1GBE_MAX_UTILIZATION.md)

**Multi-host NIC max use (host-by-host):** Phase A [hub_111_10G_NIC.md](hub_111_10G_NIC.md) -> Phase B [AI148_NIC_MAX_USE.md](AI148_NIC_MAX_USE.md) -> Phase C [hypervisor_NIC_MAX_USE.md](hypervisor_NIC_MAX_USE.md).

**Cabinet move (2026-07-27):** physical map + reachability gaps -- [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md). **2026-08-03:** `gaming-c`/`gaming-b` on **2.5 GbE** switch; `gaming-a` on **1 GbE** switch downstream. Re-baseline iperf after gaming join.

**Related baselines:** [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md), [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md), [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md) (LACP section), [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md), [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md).

---

## IP aliases do not add bandwidth

Multiple LAN IPs on the **same physical interface** are routing labels only. They share one negotiated link speed and one transmit queue.

| IPs | Host | Physical NIC | Reality |
|-----|------|--------------|---------|
| `hub`, `storage` | hub | **`br1`** (BCM + i210 + USB members) | **Same L2** — VIPs share bridge bandwidth; iperf to each alias ~947 Mbps on 1G-class paths. **`.157` retired** (historical iperf only). |
| `.104` / `apps` | VM105 | `enp6s19` + `bond0` | Data plane retired; mgmt `apps` on `bond0` only for cluster wiring |
| `inference` | ai-148 | LACP `bond0` (`eno1` + USB) | **Live 2026-07-13**; `.147` retired |
| `.92` / `orchestrator` | WOLF1 | WSL mirrored + Win11 | Same box; cluster uses **`orchestrator` only** |

Official references:

- Linux bonding modes: [kernel bonding documentation](https://docs.kernel.org/networking/bonding.html) -- `802.3ad` (LACP) needs **two physical links** and a switch that supports IEEE 802.3ad; `active-backup` (mode 1) is failover, not 2x throughput.
- Link speed query: [ethtool(8)](https://man7.org/linux/man-pages/man8/ethtool.8.html)
- NFS client: [mount.nfs(8)](https://man7.org/linux/man-pages/man8/mount.nfs.8.html)

**Do not** invent LACP across `hub` / `storage` — they are VIPs on **`br1`**, not separate cables. **`.157` retired.**

---

## Idle / underused NIC inventory

| Host | Interface | Link / speed (baseline) | Status | Notes |
|------|-----------|-------------------------|--------|-------|
| `hub` | `br1` (BCM + i210 + USB members) | 10G PHY; **`hub/24` + `storage/32` NFS VIP** | Active | Hub brain + NFS on same L2; peak **1.83 Gbps** from `inference` to `storage`; **`.157` retired** |
| `orchestrator` | Realtek 5 GbE (active) | Linked, path caps ~1 GbE | Active | Orchestrator, RPC shard `:31350` |
| `orchestrator` | 2x Intel X540 10GbE | **Disconnected** | **Out of scope** | Operator: no 2nd cable for now (2026-07-12) |
| `inference` | `bond0` (802.3ad LACP) | **~1.8 Gbps** multi-flow to `storage` | Active, **aggregated** | Live 2026-07-13; CPU RAG `:11435`/`:8360` |
| `inference` | `.147` USB data NIC | Linked at 1G | **Retired** for RAG | Policy routing kept; do not route new traffic |
| `.104` | `enp6s19` | virtio, local VM tests only | **Retired** data plane | No embed traffic; RAG on `inference` |
| `apps` | `bond0` + USB path | ~1 GbE to LAN peers | Active | **Apps vantage** for iperf; not embed/RPC host |
| `gaming-c` / `gaming-b` | mobo **2.5 GbE** | Linked (2026-08-03) | **inference opt-in** | Uplink: 2.5G switch → 10G island; iperf TBD |
| `gaming-a` | mobo **1 GbE** | Linked via 1G downstream switch | **inference opt-in** | Slowest gaming path; iperf TBD |
| WSL `.92` | `eth3` (mirrored) | Secondary on `orchestrator` box | **Not used** | Do not wire cluster services to `.92` |

Run live inventory:

```bash
# Linux peer (apps, inference, hub operator paste)
bash scripts/lan-bandwidth-inventory.sh
```

```powershell
# From orchestrator (PowerShell as operator)
powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\scripts\lan-bandwidth-inventory.ps1
```

---

## When idle is OK vs waste

| Scenario | Idle OK? | Why |
|----------|----------|-----|
| Steady inference decode after GGUF is **local** on coordinator | **Yes** | LAN carries RPC tensor activations only; weights already on disk |
| Uncabled 10G NICs (`orchestrator` X540 spare legs) | **Waste** | Hardware paid for; no extra paths until cabled |
| NFS/SMB reads of multi-GB GGUF **during** pool runtime | **Waste** | Contends with RPC on the same ~1G fabric |
| Serialized hub pulls (one worker at a time) during seed | **Waste** | Each host has its own 1G link; fan-out uses aggregate LAN |
| `inference` bond0 LACP both legs used under multi-flow | **Expected busy** | Idle single-stream still ~1G; use `-P 4` to see ~1.8G |
| `.104`/`.147` second NICs after data-plane retirement | **Expected** | Kept for policy-routing discipline; not hot path |

---

## P0 -- Hardware (operator; cabling / autoneg)

Composer cannot cable switches. These steps use **official** tooling only.

**Priority:** `hub` BCM 10G investigation first -- full runbook: [hub_111_10G_NIC.md](hub_111_10G_NIC.md).

### 1. Fix `hub` np0 to 10 GbE (if stuck at 1000 Mb/s)

**From `hub` (hub shell as `operator`):**

```bash
sudo ethtool -r enp11s0f0np0
sudo ethtool enp11s0f0np0 | grep -E 'Speed|Duplex|Supported link|Advertised link|Link detected'
```

If **Supported link modes** lacks `10000baseT/Full`, reseat cable, confirm AXE300 port is 10G, check cable category. **Do not** uncable i210 ports (rumor not in official ASRock manual). Full procedure: [hub_111_10G_NIC.md](hub_111_10G_NIC.md) and [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md).

### 2. `orchestrator` Intel X540 10GbE

**Out of scope** (operator 2026-07-12): no second cable planned. Skip until operator reopens.

### 3. Optional: second uplink on `hub`

Only with a **designed** second uplink (separate switch port or documented LACP pair). Do **not** recreate retired `br0` bridge loops. **Triple-NIC split is STALE** — superseded by **`br1`** ([hub_111_10G_NIC.md](hub_111_10G_NIC.md)).

### Verify after P0

From `inference` (production NFS path) or `apps` (apps vantage):

```bash
bash scripts/cluster-lan-iperf-matrix.sh 148-mgmt
IPERF3_PARALLEL=4 bash scripts/cluster-lan-iperf-matrix.sh 148-lacp
```

For **idle** baselines before claiming % improvement, see [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md) idle baseline procedure. Label under-load runs with `LOAD_NOTE` or `--under-load`.

Target: production paths **`inference` <-> `storage`** above 1 GbE where LACP is live; cross-host 1G peers ~940+ Mbps at idle.

---

## P1 -- Software (repo policy; no compose breakage)

### Local GGUF: seed on hub, run from local `MODELS_DIR`

**Policy:** Hub NFS/SMB is for **seed and sync windows only**. During inference **runtime**, the coordinator must read GGUF from **local disk cache**, not live NFS.

| Host | Seed source (hub) | Runtime `MODELS_DIR` (local) |
|------|-------------------|------------------------------|
| `hub` coordinator | `/mnt/HDDs/Alfa-AI/llama-cpp/models/` | Hub local path (coordinator on same box) |
| `inference` | NFS `orchestrator:/mnt/HDDs/Alfa-AI` -> `/mnt/cluster/llama-cpp/models/` | Prefer `$HOME/alfa-ai-cache/llama-cpp/models` when NFS not mounted for runtime |
| `orchestrator` | Hub via `inference` NFS export or SMB `\\hub\` | WSL: `/mnt/c/alfa-ai-cache/llama-cpp/models` or `$HOME/alfa-ai-cache/llama-cpp/models` |
| Linux workers | `/mnt/cluster/llama-cpp/models/` after `scripts/mount_nfs_models.sh` | Copy/sync to local cache before `Start-Stop-AlfaAi.ps1 start` |

Production GGUF: `Qwen3.6-27B-UD-Q4_K_XL.gguf` (see [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md)).

**`orchestrator` sync helper (already in repo):**

```powershell
# From orchestrator (PowerShell as operator)
powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\sync-frontier-code-gguf-from-hub.ps1
```

**`inference` / Linux:** rsync or `cp` from `/mnt/cluster/llama-cpp/models/` to local cache; see `deploy/cluster-members/inference-coordinator/write-grev27-env.sh` fallback paths.

Existing compose and `MODELS_DIR` env wiring is unchanged -- this doc enforces **operator order**: seed locally, then start pool.

### Fan-out hub sync (parallel per host, not one multi-stream client)

During **seed windows** (outside pool decode peaks), each worker should pull from the hub **in parallel** -- one transfer process **per host**, each using that host's own 1G (or 10G) link. Do **not** run many parallel rsync/scp streams **from one client** to smash one file; that still uses one uplink.

Runbook printer (no nested SSH; operator runs one command per host):

```bash
bash scripts/hub-artifact-fanout-pull.sh --print-runbook
```

Artifact classes and hub-first rules: [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md). Workers never download artifacts **>100 MB** from the public internet when the hub has a copy ([hub-hub-first policy](../.cursor/rules/hub-hub-first.mdc)).

| Artifact | Per-host pull helper |
|----------|---------------------|
| Ollama tags | `deploy/cluster-members/_common/pull-models.sh` (Linux) / `pull-models.ps1` (Windows) |
| llama.cpp RPC image | `deploy/cluster-members/_common/load-llamacpp-rpc-from-hub.sh` |
| inference GGUF (`orchestrator`) | `deploy/cluster-members/orchestrator/sync-frontier-code-gguf-from-hub.ps1` |
| NFS mount (Linux) | `scripts/mount_nfs_models.sh` then rsync from `/mnt/cluster/...` |

### P2 -- Later (not default)

- **LACP (`802.3ad`)** only after two physical cables + switch support ([kernel bonding](https://docs.kernel.org/networking/bonding.html)).
- Re-purpose `.147` or second NIC for **NFS-only** with policy routing -- operator must cable and accept ARP sysctl discipline ([CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md) dual-NIC section).

---

## Success criteria (operator checklist)

- [ ] Inventory script run on `hub`, `inference`, `apps`; idle/wrong-speed lines reviewed
- [ ] `hub` Phase A complete per [hub_111_10G_NIC.md](hub_111_10G_NIC.md) live evidence table
- [x] `inference` LACP live per [AI148_NIC_MAX_USE.md](AI148_NIC_MAX_USE.md) (AXE300 LAN3+LAN4)
- [x] `hypervisor` dual-bridge live per [hypervisor_NIC_MAX_USE.md](hypervisor_NIC_MAX_USE.md) (`vmbr0`/VM100 on `nic0`, `vmbr1`/other VMs on `nic1`)
- [ ] inference GGUF present in **local** `MODELS_DIR` on coordinator host before cluster start
- [ ] Hub seed jobs use fan-out (one pull per worker host), scheduled outside decode peaks
- [ ] **Idle** iperf on production paths (`inference` <-> `storage`, `inference` <-> `hub`/`orchestrator`) recorded in [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md)
- [ ] Under-load iperf labeled with `LOAD_NOTE`; not used alone for % improvement claims

---

## Related

- [hub_111_10G_NIC.md](hub_111_10G_NIC.md) -- Phase A `hub` hardware and investigation
- [AI148_NIC_MAX_USE.md](AI148_NIC_MAX_USE.md) -- `inference` LACP (`802.3ad`)
- [hypervisor_NIC_MAX_USE.md](hypervisor_NIC_MAX_USE.md) -- Phase C `hypervisor` dual-bridge
- [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md) -- full IP map and iperf matrix
- [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md) -- hub NIC speed tests (`br1` SSoT; triple-NIC section is historical only)
- [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md) -- LACP pointer, pool perf knobs
- [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) -- hub paths and seed policy
- [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) -- `MODELS_DIR`, coordinator bring-up
- `scripts/lan-bandwidth-inventory.sh` / `scripts/lan-bandwidth-inventory.ps1`
- `scripts/hub-artifact-fanout-pull.sh`
