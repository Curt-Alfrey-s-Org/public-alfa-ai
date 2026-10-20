# WOLF1 `.92` dual X540 (92A / 92B) — Phase 1

**Host:** `orchestrator` WOLF1 (same box). **Production (2026-09+):** orchestrator **`orchestrator/24`**, gateway **`.1`**, DNS **`.1`** on **Network Bridge** (dual **10G** X540 members) — **not** a 5G downgrade.
**Historical:** optional **`orchestrator/24`** on the same bridge; optional **Realtek 5GbE** second NIC for a split mgmt path when cabled.
**Goal (Phase 1):** name, cable, and verify both Intel X540 ports before any Windows bridge.
**Parent design:** daisy-chain so AXE300's single 10G can serve `hub` and the Yuanley 10G island via software bridge(s). See [hub_111_10G_NIC.md](hub_111_10G_NIC.md).

**Post-cabinet-move (2026-07-27):** full cluster cable map is [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md). **After operator swap:** **92A → Yuanley**; **92B → `hub` BCM 10G**; other BCM (`br1` L2 member) → `inference` USB. NFS VIP **`storage` is on `br1`**, not that PHY. Ping `hub` OK.

**Official bridge tool (later phase):** [netsh bridge](https://learn.microsoft.com/en-us/windows-server/networking/technologies/netsh/netsh-bridge) — **not** `New-NetSwitchTeam` (Hyper-V switch team only).

---

## Identify NICs by MAC (not `Ethernet N` alone)

After a **Windows network OEM reset**, **`Get-NetAdapter` InterfaceAlias numbers can permute**. Always match **MAC** before cabling or bridge commands.

| Label | Chip | MAC | Role (cabling) |
|-------|------|-----|----------------|
| **92A** | X540-AT2 | `98-B7-85-21-1F-D7` | **Yuanley** 10G |
| **92B** | X540-AT2 #2 | `98-B7-85-21-1F-D8` | **`hub` BCM 10G** |
| **orchestrator** | **Network Bridge** | (multiplexor) | **`orchestrator/24`**, gateway **`.1`**, DNS **`.1`** (10G spine) |
| **optional** | Realtek 5GbE | `BC-FC-E7-E9-44-A7` | **Not required.** Second path to LAN when cabled; **do not** move **`orchestrator`** here to "gain speed" — that would leave the orchestrator on 5G |

**Live mapping (2026-09-24 after OEM reset on `orchestrator`):**

| Label | Windows name (today) | Link |
|-------|----------------------|------|
| **92A** | `Ethernet 2` | Up 10 Gbps |
| **92B** | `Ethernet 5` | Up 10 Gbps |
| **`orchestrator` (production)** | `Network Bridge` | Up 20 Gbps (display) |
| **Realtek (optional)** | `Ethernet 4` | **Disconnected** is OK — leave uncabled if unused |

Historical mapping (pre-reset): 92A = `Ethernet 4`, 92B = `Ethernet 5`, Realtek = `Ethernet 2` — same MACs, different aliases.

**Verify (read-only, `operator`):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\Verify-Wolf1NetworkLayout.ps1
```

---

## Production layout vs optional Realtek split (2026-09-24)

| Layout | Required? | IPv4 | Gateway | Speed for **`orchestrator`** |
|--------|-----------|------|---------|---------------------|
| **Production (default)** | **Yes** | **`orchestrator/24`** on **Network Bridge** | **`.1` on bridge** | **10G** (X540 spine) |
| **Optional split (legacy doc)** | **No** | **`.92/24`** bridge + **`orchestrator/24`** Realtek | **`.1` on Realtek only** | **5G** on Realtek — **avoid** for orchestrator unless you explicitly want a second NIC |

**Operator policy (2026-09-24):** Keep **`orchestrator` on the 10G Network Bridge**. Realtek does **not** need to be cabled for cluster ops. Cabling Realtek is **optional** (extra LAN leg / lab); moving **`orchestrator`** to Realtek is **not** an upgrade — it **slows** the orchestrator host to 5G.

**Production checklist (Admin `operator` only when fixing):**

1. **92A + 92B** in **Network Bridge** (match MACs, not `Ethernet N` labels).
2. **`orchestrator/24`**, gateway **`orchestrator`**, DNS **`orchestrator`** on **Network Bridge** only (single default route).
3. **Network Bridge** profile **Private** (LAN ICMP from `hub`). See [CLUSTER_DNS_AND_GATEWAY.md](CLUSTER_DNS_AND_GATEWAY.md).
4. Re-run **`Verify-Wolf1NetworkLayout.ps1`** — expect **PRIMARY** and **PASS**.
5. On **both** X540s, **Large Send Offload V2 (IPv4)** and **Large Send Offload V2 (IPv6)** = **Disabled**. See below.

**Large Send Offload (required while `orchestrator` is on the bridge, 2026-10-02):**

Intel documents this as an optional transmit offload on the adapter **Advanced** tab ([Large Send Offload](https://edc.intel.com/content/www/us/en/design/products/ethernet/adapters-and-devices-user-guide/30.3/large-send-offload-ipv4-and-ipv6/)). With both X540s in the Windows bridge and **`orchestrator` on that bridge**, leaving **V2** enabled made **uploads from `orchestrator`** crawl (**about 0.5 Mb/s**) while downloads stayed about **72 Mb/s** and a host behind the bridge (`inference`) could still upload. After **Disabled** on both X540s, Ookla from `orchestrator` was **ping 28 ms, download 72 Mb/s, upload 26 Mb/s**, and a 1 MB POST from `orchestrator` dropped from **17 s** to **1 s**. LAN pings to **`hub` `inference` `hypervisor` `apps` `gaming-b`** stayed OK. The bridge and **`orchestrator`** address do not move.

Device Manager path: **Network adapters** → **Intel(R) Ethernet Controller X540-AT2** and **X540-AT2 #2** (match MAC if the `Ethernet N` name changed) → **Properties** → **Advanced**. Do not change **Microsoft Network Adapter Multiplexor Driver**.

**Optional split (only if you deliberately want two host NICs):** steps in git history / pre-2026-09 runbooks — **not** the default after OEM reset.

**Wi-Fi:** disable **`Wi-Fi 2`** or DNS **`.1` only** and no default route — do not leave **`orchestrator` / public DNS** on the orchestrator ([CLUSTER_DNS_AND_GATEWAY.md](CLUSTER_DNS_AND_GATEWAY.md)).

---

## Live inventory (2026-07-12 historical aliases; use MAC table above)

| Label | Windows name (2026-07) | Chip | MAC | Role |
|-------|------------------------|------|-----|------|
| **92A** | `Ethernet 4` | X540-AT2 | `98-B7-85-21-1F-D7` | Yuanley |
| **92B** | `Ethernet 5` | X540-AT2 #2 | `98-B7-85-21-1F-D8` | `hub` BCM 10G |
| **optional** | `Ethernet 2` | Realtek 5GbE | `BC-FC-E7-E9-44-A7` | unused or legacy split only |

**Proven:** BCM np1 <-> X540 = **10 Gbps** (same day as AXE300 direct 10G on np0). Yuanley is not required for that hop.

### Operator cable map (2026-07-27 post-move, after swap)

```
AXE300 10G --> Yuanley --> 92A (MAC ...1F:D7; often `Ethernet 2` after 2026-09 reset)
92B (MAC ...1F:D8; `Ethernet 5`) --> hub BCM 10G
(hub other BCM / br1 L2 member --> inference USB; storage VIP on br1 -- see CLUSTER_CABINET_CABLE_MAP.md)
```

### Operator cable map (historical 2026-07-12)

```
AXE300 10G --> hub np0 (hub)
hub np1 (storage) --> 92B Ethernet 5 --[Windows bridge]-- 92A Ethernet 4 --> Yuanley
```

**Agent has no SSH to `hub`** -- operator (`operator`) only.

### hub bridge (operator 2026-07-12 — **historical**; superseded 2026-09-04 `br1`)

| Interface | Role |
|-----------|------|
| **`br1`** | **Current:** all cabinet members; IPs **`hub/24` + `storage/32`** on bridge only |
| **`enp6s0` / `enp7s0`** (i210 1G) | **`br1` members** (L2 only) — see [hub_111_10G_NIC.md](hub_111_10G_NIC.md) |
| Physical np0/np1 | No standalone cluster IPv4 (bridge slaves) |

---

## Phase 2 — Windows bridge (done 2026-07-12)

| Step | Result |
|------|--------|
| `netsh bridge create 30 21` | Ethernet 4 (30) joined; Ethernet 5 (21) failed first pass |
| `netsh bridge add 21 to "{GUID}"` | Ethernet 5 joined (quote GUID in PowerShell) |
| `New-NetIPAddress` on Network Bridge | **`orchestrator/24`** — AddressState **Preferred** |
| Verify | Ping **`hub` / `storage` / `.92`** OK from WOLF1; both X540 **Up 10 Gbps**; bridge shows **20 Gbps** (aggregate display) |
| `hub` ethtool (2026-07-12) | **np0 = 10000Mb/s** (AXE300); **np1 = 10000Mb/s** (X540 92B) — full daisy-chain copper at 10G |

Bridge GUID (this host): `{A7E8C9E2-17B3-4B64-A8A5-10899F055D18}`

**Production:** one default gateway on **Network Bridge** with **`orchestrator`**. **Optional split:** gateway on Realtek only — **never** two gateways on bridge + Realtek.

---

## Phase 1 steps (92A-B cabling — done)

1. **Leave 92A** on Yuanley (keep proven 10G).
2. **Cable 92B** (`Ethernet 5`) to **`hub` LAN4** (`enp11s0f1np1`).
3. Both links **Up 10 Gbps** (BCM np1 <-> X540 proven).
4. hub **`br1`**: cabinet members; IPv4 **`hub/24` + `storage/32`** on the bridge only (not `storage/24` -- see [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md) src-bug).

---

## Later verify (full daisy-chain)

From a Yuanley-side host (or WOLF1): reach `orchestrator` / AXE300 path via the bridge. Optional: `iperf3` `.92` <-> `hub`.

Official create/add: [netsh bridge](https://learn.microsoft.com/en-us/windows-server/networking/technologies/netsh/netsh-bridge).

```text
netsh bridge show adapter
netsh bridge list
```

GUI alternative: Network Connections → select both → Bridge Connections.

**Effects:** **Production** — **`orchestrator`** on **Network Bridge**; X540 ports are bridge members at 10G. WOLF1 reboot drops cabinet spine + orchestrator until Windows is back.

---

## Related

- [hub_111_10G_NIC.md](hub_111_10G_NIC.md) — BCM / Yuanley / AXE300 evidence
- [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md) — `.92` = WSL secondary on WOLF1
- [NODE_INVENTORY.md](NODE_INVENTORY.md) — update X540 cabling when Phase 1 done
