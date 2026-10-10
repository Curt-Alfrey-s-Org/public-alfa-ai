# Proxmox `hypervisor` (pve-i5) -- dual-NIC traffic split (SSoT)

**Host:** `orchestrator` (MSI B365M PRO-VDH, i5-9600K, Proxmox VE 9.2.x).
**Goal:** Use **both** 1 GbE NICs as **two independent uplinks** -- not LACP (router LAG reserved for `inference`).
**Design:** Dual-bridge traffic split: **`vmbr0` @ `hypervisor`** on `nic0`, **`vmbr1` @ `.228`** on `nic1`.

**Official ref:** [Proxmox VE network configuration](https://pve.proxmox.com/pve-docs/chapter-sysadmin.html#sysadmin_network_configuration)

**Bandwidth reality:** Two bridges = **~1 Gbps per bridge** (~2 Gbps aggregate only when **different VMs** send traffic at the same time). Single VM / single TCP flow stays at **~1 Gbps**.

---

## Live state (authoritative 2026-07-12)

### Host bridges (Proxmox UI + operator verify)

| Bridge | Slave | Host IPv4 | Gateway | VLAN aware |
|--------|-------|-----------|---------|------------|
| **`vmbr0`** | **`nic0`** (`2c:f0:5d:0f:18:4d`) | **`orchestrator/24`** | **`orchestrator`** | Yes |
| **`vmbr1`** | **`nic1`** (`7c:c2:c6:47:4f:dd`, USB Ethernet) | **`orchestrator/24`** | **none** | Yes |

| NIC | Link | In bridge |
|-----|------|-----------|
| `nic0` | UP 1000 Mb/s | `vmbr0` only |
| `nic1` | UP 1000 Mb/s | `vmbr1` only |

**LACP retired on `hypervisor`:** prior `bond0` (802.3ad) removed; router one 2-port LAG moves to **`inference`**.

**`.228` purpose:** IDs the **nic1** uplink (`ping orchestrator`); host diagnostics / iperf on second path. **Default route** stays on **`vmbr0` (`hypervisor`)** only.

### VM placement (single virtio NIC per VM)

| VMID | Name | `net0` bridge (pre-move) | Guest IP | Role |
|------|------|--------------------------|----------|------|
| **100** | ALFA-AI | was **`vmbr0`** | `pool-opt-in/24` | inference shard `:31354` |
| **102** | MARKET | was **`vmbr1`** | `market/24` | market-pie5-bot |
| **103** | ATEMS | was **`vmbr1`** | `atems/24` | atems |
| **105** | UBUNTU-PRO-WEBSITES | was **`vmbr1`** | `apps/24` on guest **`bond0`** | Apps / bots -- see cabinet map VM105 |
| **106** | ProBilliards | was **`vmbr1`** | `probilliards/24` | rankings / USPBF |
| **107** | Grafana | was **`vmbr1`** | `monitor/24` | monitoring |
| **110** | ALFA-RAG | was **`vmbr0`** | `rag/24` | CPU RAG |
| 101 | temp | (operator) | — | scratch |

**2026-07-27+:** operator temporarily swapped bridges (100/110 ↔ apps); then `hypervisor` host redesign (`enp2s0` + USB `/32`s). **Re-confirm `qm config <vmid> \| grep net` after host recovery** and update this table.

**VM105 (2026-07-30 live):** `net0: virtio=BC:24:11:5F:44:FA,bridge=vmbr1,firewall=1`. Guest: **`bond0`** ← `enp6s18` → **`apps/24`**. **CPU-only** (no GPU passthrough; 1660S is on VM100). SSH OK. Full table: [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md) VM105 section.

**Retired:** per-VM dual virtio (`net0`+`net1`), guest `.104` data-plane IP (unless `net1` re-added), and Proxmox **`bond0` LACP** on the hypervisor.

### Do not dual-home guests on both bridges

Per [Proxmox Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration): attaching one VM to **both** `vmbr0` and `vmbr1` on the same `/24` causes ARP flux and dual-gateway confusion. **One virtio NIC per VM** on the correct bridge is the live design.

If a single VM needs more than ~1 Gbps, the official scale path is **LACP bond of physical NICs into one bridge** (as on `inference`), not a second guest NIC on the other Proxmox bridge.

### Operator verify (2026-07-12)

```text
vmbr0            UP   orchestrator/24
bridge link: nic0 master vmbr0 (only physical slave)
ping orchestrator OK from pve-i5
```

---

## Cabling

| Cable | Switch port |
|-------|-------------|
| **`nic0`** | One normal **1 GbE** port (not in `inference` LAG pair) |
| **`nic1`** | A **different** normal **1 GbE** port |

Both NICs may show link **UP** even when idle; only the bridge assignment matters.

**Post-cabinet-move:** see [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md) (2026-07-30 revise).

| Date | Live note |
|------|-----------|
| 2026-07-27 | `enp2s0` DOWN; `nic0`→vmbr0 `hypervisor`; `nic1`→vmbr1 `.228`; vmbr1 guests dark from LAN |
| 2026-07-30 | Reboot after cable swap lost host net (bridges still on old `nic*`). Operator: **1G switch** from `hub`; **`enp2s0` + one USB** on switch; plan `vmbr0`=`enp2s0` **`hypervisor/24`**, `vmbr1` USB **`.227/32`**, `vmbr2` USB **`.228/32`** |

Proxmox only uses NICs listed in `bridge-ports` -- it does not scan for a new uplink after a cable move.

---

## Why dual-bridge (not LACP here)

- AXE300 allows **one** 2-port LAG ([TP-Link FAQ](https://www.tp-link.com/au/support/faq/1583/)) -- assigned to **`inference`** inference host.
- `hypervisor` gets **traffic split**: mgmt + VM100 on `nic0`, bulk of VM fleet on `nic1`.
- Ref: [kernel bonding](https://docs.kernel.org/networking/bonding.html) -- `802.3ad` needs switch LACP; dual-bridge does not.

---

## Change runbook (reference)

### New `vmbr1` (already applied)

Proxmox UI: **System -> Network -> Create -> Linux Bridge**

- Name `vmbr1`, bridge ports **`nic1`**, IPv4 **`orchestrator/24`**, **no gateway**.

### Move a VM to `vmbr1`

Per VM: **Hardware -> Network Device (`net0`) -> Edit -> Bridge `vmbr1`**. Guest IP unchanged (e.g. `apps` stays `apps`).

### VM100 stays on `vmbr0`

**Hardware -> net0 -> Bridge `vmbr0`**.

### Verify

**On `hypervisor` (root):**

```bash
bridge link show | grep -E 'nic0|nic1'
qm config 100 | grep '^net'
qm config 105 | grep '^net'
ping -c 2 orchestrator
```

Expect: `nic0` -> `vmbr0` only; `nic1` -> `vmbr1` only; VM100 `net0` = `vmbr0`; VM105 `net0` = `vmbr1`.

---

## iperf (optional baseline)

**On `hypervisor`:**

```bash
bash scripts/iperf3-bootstrap.sh
```

**From `apps`:**

```bash
bash scripts/cluster-lan-iperf-matrix.sh 105-mgmt
```

Record `hypervisor` and `.228` rows in [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md).

---

## STOP conditions

- Both NICs on one bridge (`vmbr0` with `nic0 nic1`) -- breaks split; use one slave per bridge
- Gateway on **both** `vmbr0` and `vmbr1` -- duplicate default routes
- Re-enable LACP on `hypervisor` while `inference` uses router LAG -- only one host per LAG group
- **Dual-home one guest on `vmbr0` and `vmbr1`** on the same `/24` -- ARP flux; forbidden per Proxmox bridge docs

---

## Success criteria (2026-07-12)

- [x] `vmbr0` @ `hypervisor` on `nic0` only; gateway `.1`
- [x] `vmbr1` @ `.228` on `nic1` only; no gateway
- [x] VM100 on `vmbr0`; VMs 102/103/105/106/107 on `vmbr1`
- [ ] iperf baseline recorded (optional)

---

## Related

- [AI148_NIC_MAX_USE.md](AI148_NIC_MAX_USE.md) -- `inference` LACP (router LAG)
- [LAN_BANDWIDTH_UTILIZATION.md](LAN_BANDWIDTH_UTILIZATION.md)
- [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md)
- [NODE_INVENTORY.md](NODE_INVENTORY.md) -- pve-i5 section
- `deploy/cluster-members/hypervisor/setup-dual-ip-data-plane.sh` (automation reference; live config applied via UI)
