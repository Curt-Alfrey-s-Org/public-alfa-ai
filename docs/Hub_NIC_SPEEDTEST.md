# hub (hub) multi-NIC speed test

**Quick sweep (all cluster IPs):** from a Linux peer run
[`scripts/cluster_lan_speedtest.sh`](../scripts/cluster_lan_speedtest.sh). The
orchestrator runs **ping + iperf3 upload + iperf3 download** against every
target by default, prints a summary table, and emits per-host bootstrap hints
for any host that is not listening. Prep each target **once** with
[`scripts/iperf3-bootstrap.sh`](../scripts/iperf3-bootstrap.sh) (Linux) or
[`scripts/iperf3-bootstrap.ps1`](../scripts/iperf3-bootstrap.ps1) (Windows);
both are idempotent and `--restart unless-stopped`. For **egress binding** from
`hub` only (which NIC carries which traffic), use the `iperf3 -B` loop below.

**Current layout (live 2026-09-04):** **`br1` is the LAN.** Per [hub bridge setup](https://www.hub.com/docs/scale/network/interfaces/settingupbridge/), IPv4 belongs on the bridge; enslaved members (BCM np0/np1, i210, USB) are L2-only. **`hub/24` + `storage/32` NFS VIP** on `br1` — same L2, not separate wires. **`.157` / `.173` retired** (Petals inference removed 2026-07-09). Full SSoT: [hub_111_10G_NIC.md](hub_111_10G_NIC.md).

**Stale (do not document as current):** Jun 2026 "np0 only / `enp11s0f1np1` not in use"; Jul 2026 triple-NIC split (each IP on its own PHY). Historical `br0` bridge (Apr 2026) — retired after loop remediation.

| IP | Role (current) |
|----|----------------|
| `hub` | Mgmt on **`br1`** — API, LiteLLM, registry, SMB, Dockge, default src |
| `orchestrator` | NFS VIP on **`br1`** `/32` — nfsd bind; clients prefer this, **`hub` fallback** same L2 |
| `orchestrator` | **Retired** — was Petals `PETALS_ANNOUNCE_IP` (historical iperf rows may still list it) |
| `orchestrator` | **Retired** — do not use |

**Historical (Jun 2026 LAN sweep, `apps` → each IP, `iperf3`, TCP 5201, 4
streams, 10 s):** every online target with `iperf3-bootstrap` running sustained
**~937–948 Mbit/s** upload and **~936–941 Mbit/s** download. **`orchestrator` → `hub`
direct** (5 Gbps client to 10 GbE hub) also caps at **~952 / ~941 Mbit/s** —
the **switch/uplink segment** is the bottleneck, not host NICs. Treat all
measured paths as **1 GbE-class** until `orchestrator`'s **Intel X540 10GbE** pair is
cabled or a faster peer is used as the iperf runner. Prior **Apr 2026** baseline
was **~920–950 Mbit/s** (unchanged). Those numbers are **same-L2 / `br1`** baselines.

---

## 1. Identify each interface on hub

hub UI → **Network** → **Interfaces** shows the physical NIC, its MAC,
its link speed, and which IP is bound. Take a screenshot or copy the table
into this doc's "results" section at the bottom. Alternatively:

```bash
# on hub -- IPv4 is on br1; ethtool the PHY (member), not the VIP
ssh operator@hub
ip -br addr show br1
sudo ethtool enp11s0f0np0 | grep -E 'Speed|Duplex|Supported link|Advertised link|Link detected'
```

Record: `iface name`, `mac`, `link speed (Mb/s)`, `IP`.

### Restart autoneg on `enp11s0f0np0` (np0)

When np0 negotiates **1000Mb/s** but should be **10 GbE** to the AXE300,
restart autonegotiation ([ethtool(8) `-r`](https://man7.org/linux/man-pages/man8/ethtool.8.html)):

```bash
sudo ethtool -r enp11s0f0np0
sudo ethtool enp11s0f0np0 | grep -E 'Speed|Supported link|Advertised link|Link detected'
```

If **Supported link modes** still lists only `1000baseT/Full` (no
`10000baseT/Full`), the NIC is not seeing a 10G PHY — reseat cable, confirm
AXE300 port is 10G, check SFP/module. Do not use `br0`; changes apply to
**`enp11s0f0np0`** directly. Persist via hub **System → Advanced → Init
Scripts** only if `-r` is needed every boot.

## 2. Install `iperf3` in a Docker container on a LAN peer

Pick a peer with known fast NIC — `apps` is the simplest because it's wired
into the same switch as `hub`. On `apps`:

```bash
sudo docker run --rm --network host networkstatic/iperf3 -s -p 5201
# leave this running in one terminal
```

## 3. Run `iperf3` from `hub` to `apps` via each live VIP on `br1`

From `hub`, open a shell (SSH to `hub`, then):

```bash
# Bind to each live VIP on br1. Same L2 -- this is source-IP bind, not a
# separate NIC plane. Do not include retired .157.

for src in hub orchestrator; do
  echo "=== egress via $src ==="
  docker run --rm --network host networkstatic/iperf3 \
    -c apps -p 5201 -B "$src" -t 15 -P 4 -i 5
  echo
  sleep 2
done | tee /tmp/nic-speedtest.$(date -u +%Y%m%dT%H%M%SZ).log
```

Flags:

- `-B <src>` binds the client socket to that local IP. On `br1` both
  `hub` and `storage` egress the same bridge (not separate PHYs).
- `-P 4` four parallel TCP streams — a single-stream 2.5 GbE link
  sometimes underreports because of TCP window size on older NICs.
- `-t 15 -i 5` 15-second run, progress every 5 s.
- `-R` reversal can be added for a second pass measuring ingress
  (`apps → hub`). Run both directions; the slow direction is what
  actually limits NFS hub traffic (same-L2 / `br1` VIPs).

## 4. Cross-check with a second peer (`orchestrator`, Windows)

On `orchestrator` in PowerShell (**Docker Desktop**). Windows does **not** support
`--network host`; publish the port instead:

```powershell
docker run --rm -p 5201:5201 networkstatic/iperf3 -s -p 5201
```

Then on `hub` (Linux):

```bash
docker run --rm --network host networkstatic/iperf3 -c orchestrator -p 5201 -B orchestrator0.<src> -t 15 -P 4
```

If `hub → apps` says 2.4 Gb/s on one NIC but `hub → orchestrator` says 940 Mb/s
on the same NIC, the problem is between `orchestrator` and the switch (probably
`orchestrator`'s NIC or a bad cable), not `hub`'s. **Jun 2026 sweep:** `orchestrator → hub`
direct also caps at **~952 / ~941 Mbit/s** with `orchestrator`'s **5 Gbps** Realtek
linked — confirms the **switch segment** is the limit, not `orchestrator`'s active NIC.

## 5. Apply the result

**Current SSoT:** keep IPv4 on **`br1`** (`hub/24` + `storage/32`). Do **not**
rebind `hub` or `storage` onto a physical member while that NIC is a bridge
slave ([hub bridge setup](https://www.hub.com/docs/scale/network/interfaces/settingupbridge/)).

Use `ethtool` on members to pick the **fastest PHY** for the Yuanley/92B
uplink cable. Historical "rebind `hub` to the fastest standalone NIC" applied
only before `br1`.

LACP / Link Aggregation is a separate operator decision (hub UI,
IEEE 802.3ad on the switch) -- not a substitute for putting IPs on slaves.

## 6. Firewall notes

All **active** IPs are on **`br1`** (same LAN, same hub host). Firewall rules for registry `:5000`, Dockge `:31014`, NFS `:2049` should allow **`hub`** and **`storage`** (NFS VIP). **`.157` / `.173` retired** — historical `iperf` rows below may still list them.

---

## Results (fill in after running) — **historical captures; same-L2 / `br1` since 2026-09-04**

Older rows may label `.157` as "Petals alias" or `np1` as "unused" — **stale** pre-`br1` layout.

### Recorded sweep — 2026-04-18

From **`web-sites` (`apps`)** with **`iperf3 -s -p 5201`** on hub,
[`scripts/cluster_lan_speedtest.sh`](../scripts/cluster_lan_speedtest.sh) **`--iperf --no-ping`**:
**~930 Mbit/s sender / ~920 Mbit/s receiver** (10 s, 4 TCP streams) on **each**
of **`hub`, `.157`, `.173`, `storage`** (upload and download). **Retr 0**
on reported `[SUM]` lines — no sign of lossy links.

---

### Recorded sweep — 2026-04-25

From **`web-sites` (`apps`)** via
[`scripts/cluster_lan_speedtest.sh --auto-install`](../scripts/cluster_lan_speedtest.sh),
iperf3 3.16, 10 s, 4 TCP streams, port 5201.

**Network topology at test time:** `hub` br0 bridge (2×10 GbE) → one uplink
to AXE300 router, one uplink to 2.5 GbE switch. `orchestrator` connected to 2.5 GbE
switch via 5 Gbps port. `apps` connected to 2.5 GbE switch via USB-Ethernet
adapter. `gaming-c`, `gaming-a`, `gaming-b` share the AXE300 router's 2.5 GbE port.

#### Ping results (all hosts)

| Target | Avg RTT | Jitter | Loss | Notes |
|--------|---------|--------|------|-------|
| `hub` (`hub`) | 0.444 ms | 0.097 ms | 0% | br0 bridge, via 2.5 GbE switch |
| `storage` (NFS alias) | 0.390 ms | 0.151 ms | 0% | Same br0 bridge |
| `.157` (Petals alias) | 0.512 ms | 0.142 ms | 0% | Same br0 bridge |
| `orchestrator` | 0.509 ms | 0.053 ms | 0% | 5 Gbps → 2.5 GbE switch |
| `gaming-b` gaming-worker-b | **DOWN** | — | 100% | Host offline at test time |
| `gaming-c` gaming-worker-c | 0.906 ms | 0.140 ms | 0% | Via AXE300 router 2.5 GbE |
| `gaming-a` gaming-worker-a | 0.886 ms | 0.189 ms | 0% | Via AXE300 router 2.5 GbE |

#### iperf3 throughput (hosts with server running)

| Target | Upload (Mbps) | Download (Mbps) | Retransmits | Status |
|--------|---------------|-----------------|-------------|--------|
| `orchestrator` | **922.7** | **941.1** | 0 | OK — ~1 GbE saturated |
| `hub` / `storage` / `.157` | SKIP | SKIP | — | iperf3 server not running on hub |
| `gaming-b` | SKIP | SKIP | — | Host offline |
| `gaming-c` / `gaming-a` | SKIP | SKIP | — | iperf3 server not bootstrapped |

**Notes:** Only `orchestrator` had iperf3 listening. `apps → orchestrator` link saturates at
~940 Mbps (1 GbE ceiling from the USB-Ethernet adapter on `apps`). To get
full throughput numbers for all hosts, bootstrap iperf3 on each target per
the remediation hints in the log and re-run. `gaming-b` was powered off.

---

### Recorded sweep — 2026-06-26 (authoritative)

From **`web-sites` (`apps`)** via
[`scripts/cluster_lan_speedtest.sh`](../scripts/cluster_lan_speedtest.sh),
iperf3 3.16, 10 s, 4 TCP streams, port 5201. iperf3 bootstrapped on **`hub`**,
**`apps`**, **`orchestrator`** (WSL Docker), and **`inference`**.

**Network topology at test time:** unchanged from Apr 2026 — `hub` **br0**
(2×10 GbE), `orchestrator` on **5 Gbps Realtek** (plus **2× Intel X540 10GbE**
installed but **disconnected**), `apps` on USB-Ethernet via Proxmox `hypervisor`.
**`gaming-a` / `gaming-c` / `gaming-b`** powered off (no ping).

#### Ping results

| Target | Avg RTT | Jitter | Loss | Notes |
|--------|---------|--------|------|-------|
| `hub` mgmt | 0.337 ms | 0.069 ms | 0% | br0 bridge |
| `storage` NFS alias | 0.339 ms | 0.046 ms | 0% | same br0 |
| `.157` Petals alias | 0.432 ms | 0.090 ms | 0% | same br0 |
| `orchestrator` WOLF1 | 0.485 ms | 0.047 ms | 0% | 5 Gbps link, ~1 GbE path |
| `inference` ai-148 | 0.383 ms | 0.050 ms | 0% | 1 Gbps bond0 |
| `gaming-a` / `gaming-c` / `gaming-b` | **DOWN** | — | 100% | offline at scan time |

#### iperf3 throughput (`apps` → target)

| Target | Upload (Mbps) | Download (Mbps) | Retransmits | Status |
|--------|---------------|-----------------|-------------|--------|
| `hub` | **946.9** | **941.0** | ~982 | OK |
| `storage` | **947.7** | **940.9** | ~836 | OK |
| `.157` | **947.6** | **941.0** | ~1006 | OK |
| `orchestrator` | **947.4** | **941.1** | ~967 | OK |
| `inference` | **946.9** | **936.4** | ~1174 | OK |
| `gaming-a` / `gaming-c` / `gaming-b` | — | — | — | offline |

#### Direct path — `orchestrator` → `hub` (WSL Docker iperf3 client on `orchestrator`)

| Direction | Throughput (Mbps) | Retransmits | Notes |
|-----------|-------------------|-------------|-------|
| Upload (`orchestrator` → `hub`) | **952** | 0 | 5 Gbps NIC, ~1 GbE path |
| Download (`hub` → `orchestrator`) | **941** | 0 | same segment ceiling |

**Notes:** All measured paths remain **~1 GbE-class** despite faster local NICs
on `orchestrator` (5 Gbps active) and `hub` (2×10 GbE). **`apps`** USB-Ethernet is the
ceiling when `apps` is the runner. To exceed **~1 Gbps**, cable **`orchestrator`'s X540
10GbE** to the 10G switch and re-test with **`hub`** as peer (or run the
orchestrator from a host with a faster uplink).

Log: `cluster-speedtest-20260626T224252Z.log` on `apps`.

---

Date: `YYYY-MM-DD` (additional runs)
Operator: _________

### Link info (from `ethtool` / hub UI)

| IP | iface | MAC | Negotiated speed |
|----|-------|-----|------------------|
| `hub` | `enp11s0f0np0` / **`br1`** | | 1000 Mb/s (2026-06-27; target 10 G) — **historical row** |
| `orchestrator` | alias on `enp11s0f0np0` (**retired**) | | same L2 |
| `orchestrator` | NFS VIP on **`br1`** `/32` | | same L2 |
| `enp11s0f1np1` | **`br1` member** (L2 only; stale "unused") | | |

### `iperf3 hub → apps` (4 parallel TCP, 15 s)

| Egress IP | Throughput (Gb/s) | Retries | Notes |
|-----------|-------------------|---------|-------|
| `hub` | | | |
| `orchestrator` | | | |
| `orchestrator` | | | |

### `iperf3 hub → orchestrator` (4 parallel TCP, 15 s)

| Egress IP | Throughput (Gb/s) | Retries | Notes |
|-----------|-------------------|---------|-------|
| `hub` | | | |
| `orchestrator` | | | |
| `orchestrator` | | | |

### Decision (April 2026 cluster rebalance — **historical**; superseded 2026-09-04 `br1`)

- `hub` → mgmt / API / LiteLLM / registry / SMB / Dockge (was on `enp11s0f0np0`; now **`br1`**).
- `orchestrator` → NFS VIP (was "data plane" alias; now **`br1` `/32`**, same L2 as `hub`).
- `orchestrator` → **Retired** — was Petals swarm plane (`PETALS_ANNOUNCE_IP`).
- `enp11s0f1np1` → **Stale Jun 2026 claim "unused"** — now a **`br1` member** (L2 only; no host IPv4).

### Network topology (live 2026-09-04 — `br1`)

```
br1 (hub/24 + storage/32 NFS VIP)
├── enp11s0f0np0 (BCM np0) ──→ AXE300 / Yuanley path
├── enp11s0f1np1 (BCM np1) ──→ L2 member (e.g. X540 / inference USB path)
├── enp6s0 / enp7s0 (i210) ──→ hypervisor / cabinet 1G paths
└── enxc65a06c6ae7e (USB) ──→ inference USB
```

Official bridge reference: [hub Setting Up a Network Bridge](https://www.hub.com/docs/scale/network/interfaces/settingupbridge/).

---

## Triple-NIC split — **STALE / superseded 2026-09-04** (historical only)

> **Do not implement.** Do not put `hub` / `storage` / `.157` on physical NICs,
> and do not run Post Init to assign member `/32`s or tables 101/102.
> Current SSoT: **`br1`** with **`hub/24` + `storage/32`** on the bridge only
> ([hub_111_10G_NIC.md](hub_111_10G_NIC.md),
> [hub bridge setup](https://www.hub.com/docs/scale/network/interfaces/settingupbridge/)).
> Petals **`.157` is retired**.

**Historical (July 2026, before `br1`):** the idea was one IP per PHY
(`hub` on np0, `storage` on np1, `.157` on i210) plus policy routes so NFS and
Petals did not share one ~947 Mbps queue. **That layout is defeated** while
those NICs are `br1` members (same L2). Persist-script copy and leftover
member-IP removal: [hub_111_10G_NIC.md](hub_111_10G_NIC.md) operator
cleanup.

### Network topology (Apr 2026 — historical, br0 retired)

```
hub br0 (2×10 GbE) — REMOVED Jun 2026
├── Port A → AXE300 router (10 GbE uplink)
└── Port B → 2.5 GbE switch (orchestrator / apps / secondary)
```

## Related docs

- [NODE_INVENTORY.md](NODE_INVENTORY.md) — full host inventory
- [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md) — NVMe hot pool
- [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) — brain-host services
- [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) — NFS/SMB layout
