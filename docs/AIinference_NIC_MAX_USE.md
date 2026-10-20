# ai-148 (`inference`) -- dual-NIC LACP (SSoT)

**Host:** `orchestrator` (Gigabyte Z390 AORUS PRO, i7-9700K).
**Goal (historical):** **802.3ad LACP** on onboard `eno1` + USB Ethernet -> `bond0` @ `inference/24` for ~2x1G multi-flow aggregate to the router.
**Design (historical):** Single service IP on LACP bond -- **not** traffic-split `.147`/`inference`.

**Post-cabinet-move (2026-07-27):** both `inference` cables terminate on **`hub`** (mobo `eno1` → `hub` i210 1G; USB → `hub` BCM `storage` plane). **AXE300 LACP on `inference` is not applicable** until cabling returns to the router. See [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md). Restore LAN reachability via hub bridge members first; then choose active-backup / traffic-split / single-NIC on `inference`.

**Prerequisite (LACP design only):** AXE300 (or switch) **IEEE 802.3ad** LAG on the two ports cabled to `inference`. Router allows **one** 2-port LAG ([TP-Link FAQ](https://www.tp-link.com/au/support/faq/1583/)) -- move LAG from `hypervisor` to `inference` before host apply.

**Official refs:**

- [kernel bonding](https://docs.kernel.org/networking/bonding.html) -- mode `802.3ad` (LACP)
- [netplan bond parameters](https://netplan.readthedocs.io/en/stable/netplan-yaml/) -- `mode: 802.3ad`, `lacp-rate: fast`

---

## NIC inventory (live 2026-07-12)

| Interface | MAC | Speed | Role in LACP |
|-----------|-----|-------|--------------|
| `eno1` | `b4:2e:99:38:2f:c9` | 1 GbE | `bond0` slave |
| USB `nic_usb` / `enx7cc2c646ec53` | `7c:c2:c6:46:ec:53` | 1 GbE | `bond0` slave |
| `bond0` | (eno1) | aggregate | **`inference/24`** -- inference RPC, RAG, edge, SSH |

**Retired with LACP:** `.147/32` data-plane IP and policy routing table 101.

---

## Router / cable map (AXE300)

| Step | Action |
|------|--------|
| 1 | **Remove** `hypervisor` from router LAG (was LAN1+LAN2). Plug `hypervisor` **one** cable into a **non-LAG** port (e.g. LAN3). |
| 2 | **Create** router LAG on two ports for `inference` (operator choice; e.g. **LAN1 + LAN2** or **LAN2 + LAN4**). |
| 3 | Cable **`inference` `eno1`** and **USB** into those two LAG ports. |

Non-LAG ports (LAN3/LAN4 if not in the group) stay normal **1 GbE**.

---

## Mutually exclusive designs (pick one)

| Design | Script | Throughput |
|--------|--------|------------|
| **LACP (production target)** | `setup-bond-lacp.sh` | ~2x1G multi-flow |
| Active-backup bond | `setup-bond-active-backup.sh` | 1G + failover |
| Traffic split `inference` + `.147` | `setup-dual-ip-data-plane.sh` | 2x1G isolated paths |

**Do not** apply more than one.

---

## Migration runbook

### Prerequisites

- [ ] Console or IPMI on `inference` (SSH drops during `netplan apply`)
- [ ] Router LAG moved to `inference` ports **before** host script
- [ ] `hypervisor` on single non-LAG port (revert Proxmox `bond0` LACP if still active)
- [ ] `git pull --ff-only` on `inference`

### Step 1 -- Baseline iperf (optional)

**From `apps`:**

```bash
bash scripts/cluster-lan-iperf-matrix.sh 105-mgmt
```

Record `inference` row in [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md).

### Step 2 -- Live inventory

**On `inference`:**

```bash
bash scripts/lan-bandwidth-inventory.sh
```

Confirm `eno1` + USB both **UP** at 1000 Mb/s.

### Step 3 -- Apply LACP netplan

**On `inference`:**

```bash
cd ~/alfa-ai && sudo bash deploy/cluster-members/inference-coordinator/setup-bond-lacp.sh
```

Installs [netplan-bond-lacp.yaml](../deploy/cluster-members/inference-coordinator/netplan-bond-lacp.yaml). Disables `60-alfa-dual-nic.conf` if present.

### Step 4 -- Verify LACP

**On `inference`:**

```bash
cat /proc/net/bonding/bond0
```

Expect:

- `Bonding Mode: IEEE 802.3ad Dynamic link aggregation`
- `Number of ports: 2`
- Both slaves: partner MAC **not** `00:00:00:00:00:00` (AXE300 `68:7f:f0:00:74:0c`)

### Step 5 -- Post-migration iperf

**From `apps`:**

```bash
bash scripts/cluster-lan-iperf-matrix.sh 105-mgmt
```

Parallel streams should show higher aggregate to `inference` than single-flow ~940 Mbps.

### Step 6 -- Cluster verify

After network stable, operator runs full `Start-Stop-AlfaAi.ps1` stop+start from `orchestrator` per [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md).

---

## STOP conditions

- USB NIC not detected -- plug adapter, re-run Step 3
- `Number of ports: 1` after 30s -- wrong router LAG ports or one cable off LAG group; fix cabling/router before retry
- Partner MAC `00:00:00:00:00:00` on one slave -- that NIC is not in the switch LAG (same fix as `hypervisor` LACP debug)
- Attempting LACP without router 802.3ad -- stop

---

## Success criteria

- [ ] `bond0` mode **802.3ad**, **2** ports in aggregate
- [ ] Single IP **`inference/24`** only (no `.147`)
- [ ] iperf before/after recorded
- [ ] inference RPC healthy on `inference` after full cluster cycle

---

## Related

- [LAN_BANDWIDTH_UTILIZATION.md](LAN_BANDWIDTH_UTILIZATION.md)
- [hypervisor_NIC_MAX_USE.md](hypervisor_NIC_MAX_USE.md) -- `hypervisor` LAG retired when moved to `inference`
- [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md)
- [deploy/cluster-members/inference-coordinator/README.md](../deploy/cluster-members/inference-coordinator/README.md)
- `deploy/cluster-members/inference-coordinator/setup-bond-lacp.sh`
- `deploy/cluster-members/inference-coordinator/setup-bond-active-backup.sh` (revert)
