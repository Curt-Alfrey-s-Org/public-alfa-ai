# hub `hub` — B650D4U-2L2T/BCM 10GBASE-T (SSoT)

**Host:** hub Scale on ASRock Rack **B650D4U-2L2T/BCM** (`hub`, `hub`).
**Goal:** Negotiate and use **10 GbE** on the BCM57416 uplink; document silkscreen-to-Linux mapping.
**Multi-host plan:** Phase A of [LAN bandwidth utilization](LAN_BANDWIDTH_UTILIZATION.md) (`inference` / `hypervisor` follow after sign-off).

**Official hardware sources:**

| Source | URL |
|--------|-----|
| Product page | https://www.asrockrack.com/general/productdetail.asp?Model=B650D4U-2L2T%2FBCM |
| User manual PDF | https://download.asrock.com/Manual/B650D4U-2L2TBCM.pdf |
| hub interfaces | https://www.hub.com/docs/scale/network/interfaces/configuringinterfaces/ |
| hub bridge setup | https://www.hub.com/docs/scale/network/interfaces/settingupbridge/ |
| hub LACP UI | https://www.hub.com/docs/scale/25.04/scaleuireference/network/networkinterfacescreens/ |
| Linux bridge / ip-link | https://man7.org/linux/man-pages/man8/ip-link.8.html (enslaved members do not carry host IPv4) |
| ethtool(8) | https://man7.org/linux/man-pages/man8/ethtool.8.html |

---

## Onboard NIC inventory (official manual)

| Silkscreen | Controller | Speed | Connector | BIOS menu (manual) |
|------------|------------|-------|-----------|-------------------|
| IPMI_LAN | RTL8211F (BMC) | 1G | RJ45 | Dedicated IPMI -- not data plane |
| LAN1 | Intel i210 | 1G | RJ45 | Onboard I210 Lan1 enable/disable |
| LAN2 | Intel i210 | 1G | RJ45 | Onboard I210 Lan2 enable/disable |
| LAN3 | Broadcom **BCM57416** | **10GBASE-T** | RJ45 | OnBoard Broadcom Lan |
| LAN4 | Broadcom **BCM57416** | **10GBASE-T** | RJ45 | Same BCM57416 dual-port |

**No SFP+ on this SKU.** RJ45 only.

**10G port LEDs (manual section 1.6):** Green = **10 Gbps**; Orange = **1 Gbps**.

Manual label **"shared NIC"** on LAN3 = **BMC NC-SI** (BMC can use LAN3 as a shared management path). Dedicated **IPMI_LAN** (RTL8211F) is separate. Host IP `hub` on LAN3 is **not** IPMI and does **not** make LAN3 a "mgmt-only" port.

---

## Rumor: "other ports must be empty for 10G" / "mgmt must not use 10G"

| Claim | Official position |
|-------|-------------------|
| i210 LAN1/LAN2 must be uncabled for BCM 10G | **Official docs silent** -- not in manual, product page, or ASRock FAQ |
| Host "mgmt" IP must not sit on a 10G port | **Not in manuals** -- link speed is PHY; IP role is above L2 |
| "Shared NIC" on LAN3 | **Documented** -- BMC **NC-SI** sideband ([manual](https://download.asrock.com/Manual/B650D4U-2L2TBCM.pdf)); not "mgmt IP only" |

**Do not** uncable i210 ports as a "fix" for 1G negotiation. If stuck at 1000 Mb/s after official `ethtool -r`, investigate cable category, switch port capability, and autoneg per ethtool(8).

---

## hub UI target (compare your screenshot)

Use this table when pasting a **Network → Interfaces** / **Global Configuration** screenshot. SSoT detail: [hub_111_10G_NIC.md](hub_111_10G_NIC.md), DNS: [CLUSTER_DNS_AND_GATEWAY.md](CLUSTER_DNS_AND_GATEWAY.md).

### Global Configuration (Network)

| Field | Should be | Wrong (remove) |
|-------|-----------|----------------|
| **IPv4 Default Gateway** | **`orchestrator`** | **`.173`**, empty, or multiple gateways |
| **Nameserver 1** | **`orchestrator`** | **1.1.1.1**, **hub**, **orchestrator** |
| **Nameserver 2 / 3** | *(empty)* | Any public or **`edge`** duplicate |
| **Hostname** | `hub` (or your chosen name) | — |

AdGuard on **`edge`** is set **in the AXE300 admin UI**, not as a second nameserver on hub.

### Interface `br1` (bridge)

| Field | Should be | Wrong |
|-------|-----------|--------|
| **Type** | Bridge | Standalone IPs on member NICs |
| **IPv4** | **Static `hub/24`** | **`.157`**, **`.173`**, second `/24` on another iface |
| **Aliases on `br1` only** | **`orchestrator/32`** | **`storage` on `enp11s0f1np1`** or any member |
| **DHCP** | Off | — |
| **Bridge members** | `enp6s0`, `enp7s0`, `enp11s0f0np0`, `enp11s0f1np1`, USB `enx…` if cabled | Members **missing** (no path to **92B / `inference` / `hypervisor`**) |

### Member NICs (each enslaved to `br1`)

| Linux name | Silkscreen | IPv4 on member | Should be |
|------------|------------|----------------|-----------|
| `enp11s0f0np0` | BCM LAN3 | **none** | Bridge slave only (Yuanley / 92B path) |
| `enp11s0f1np1` | BCM LAN4 | **none** | Bridge slave only (`inference` USB leg) |
| `enp6s0` | i210 LAN1 | **none** | Bridge slave (`inference` eno1 peer) |
| `enp7s0` | i210 LAN2 | **none** | Bridge slave (**hypervisor** / 1G switch); **no `.157/32`** |
| `enxc…` | USB | **none** | Bridge slave if present |

### Retired addresses (delete if still in UI or shell)

| IP | Action |
|----|--------|
| **`orchestrator`** | Remove from **`enp7s0`** or anywhere (Petals retired) |
| **`orchestrator`** | Remove everywhere (retired) |
| **`orchestrator`** on **`enp11s0f1np1`** | Delete; keep **only** on **`br1`** as `/32` |

### After UI matches (shell verify on `hub`)

```bash
ip -br addr
ip route | head -3
ping -c2 orchestrator
```

**Pass:** **`br1`** shows **`hub/24`** and **`storage/32`**; members have **no** IPv4; **`ping orchestrator`** succeeds.

---

## Current cluster use (live 2026-09-04)

**SSoT:** **`br1` is the LAN.** Cabinet cables (Yuanley/92B, `inference` USB, i210 to `hypervisor`, both BCM ports) are **one L2 domain** bridged on `br1`. Per [hub bridge setup](https://www.hub.com/docs/scale/network/interfaces/settingupbridge/) and [ip-link(8)](https://man7.org/linux/man-pages/man8/ip-link.8.html), **IPv4 belongs on the bridge**; enslaved members are L2 forwarding only and must **not** carry cluster IPv4.

| IP | Role | Correct binding | Addressing |
|----|------|-----------------|------------|
| `hub` | Mgmt -- brain API, LiteLLM `:8413`, registry, SMB, Dockge, default src | **`br1`** | `/24` primary |
| `orchestrator` | NFS bind VIP (same L2 as `hub`, not a separate wire) | **`br1`** | `/32` alias |
| `orchestrator` | **Retired** (Petals announce) | -- | Do not use for new traffic |
| `orchestrator` | **Retired** | -- | Do not use |

**Stale (do not document as current):** Jun 2026 "all three IPs as aliases on `enp11s0f0np0` / np1 unused"; Jul 2026 "triple-NIC split" (each IP on its own PHY). While those NICs are **`br1` members**, they share the same L2 -- the July split is **defeated**.

**Live 2026-09-04 `ip -br addr` (hub 25.10.6):**

| Interface | IPv4 | Status |
|-----------|------|--------|
| `br1` | `hub/24` + `storage/32` | **Correct** |
| `enp11s0f0np0` | none | **Correct** (bridge slave) |
| `enp11s0f1np1` | `storage/32` | **WRONG** -- Post Init duplicate; remove from member |
| `enp7s0` | `.157/32` | **WRONG** -- leftover Petals; remove from member |
| `enp6s0` | none | **Correct** (bridge slave) |

**`bridge link` (2026-09-04):** all forwarding on `br1` -- `enp6s0`, `enp7s0`, `enp11s0f0np0`, `enp11s0f1np1`, `enxc65a06c6ae7e` (USB).

**Routing (2026-09-04):** `ip route get orchestrator` -> `dev br1 src hub` (good). `ip route get orchestrator from orchestrator` -> `dev enp11s0f1np1 table 101` (Post Init policy -- remove after persist script copy).

### Operator cleanup (after repo pull + persist copy)

hub UI keeps **`hub/24` + `storage/32` on `br1`**. Do **not** pull members out of `br1` from the shell (can drop SSH). After the persist script no longer re-adds member IPs ([ip-address(8)](https://man7.org/linux/man-pages/man8/ip-address.8.html), [ip-rule(8)](https://man7.org/linux/man-pages/man8/ip-rule.8.html)):

1. Copy `scripts/hub-triple-nic-setup.sh` to `/mnt/HDDs/Alfa-AI/sbin/` (members pull; no SCP-of-code).
2. `sudo ip addr del orchestrator/32 dev enp11s0f1np1`
3. `sudo ip addr del orchestrator/32 dev enp7s0`
4. `sudo ip rule del from orchestrator lookup 101` (repeat for table 102 / `.157` if present)
5. Verify: `ip -br addr` shows those VIPs **only on `br1`**; `ip route get orchestrator` still `src hub`.

**Linux names (live 2026-09-04, `ip -br link`):**

| Linux iface | Silkscreen (expected) | Chip | Role on `br1` |
|-------------|----------------------|------|---------------|
| `br1` | (bridge) | -- | **Only** cluster IPv4 (`hub` + `storage`) |
| `enp11s0f0np0` | LAN3 (BCM port 0) | BCM57416 | Cabinet / Yuanley path (L2 member) |
| `enp11s0f1np1` | LAN4 (BCM port 1) | BCM57416 | `inference` USB / data path (L2 member) |
| `enp6s0` | LAN1 | Intel i210 | `inference` eno1 peer (L2 member) |
| `enp7s0` | LAN2 | Intel i210 | `hypervisor` / cabinet (L2 member) |
| `enxc65a06c6ae7e` | USB Ethernet | unknown | Cabinet (L2 member) |

Negotiated speed per port: `ethtool` on each member (Steps 3-8). Historical iperf numbers below are **same-L2 / `br1`** tests, not separate NIC planes.

---

## Live evidence (operator fills after investigation)

**Status:** **10G proven** on direct AXE300 (2026-07-12). **Blocked** on Yuanley path -- isolate switch port or patch cable next.

| Field | Value |
|-------|-------|
| Investigation date | 2026-07-12 |
| Step 1 `ip -br link` | Both BCM (`np0`, `np1`) and both i210 (`enp6s0`, `enp7s0`) **UP** |
| Step 2 `ip -br addr` (2026-07-12) | **Historical triple-NIC split** (superseded 2026-09-04 by `br1`); see [Current cluster use](#current-cluster-use-live-2026-09-04) |
| Step 2 `ip -br addr` (2026-09-04) | **`br1`:** `hub/24` + `storage/32`; wrong extras on `enp11s0f1np1` (`storage`) and `enp7s0` (`.157`) |
| `bridge link` (2026-09-04) | `enp6s0`, `enp7s0`, `enp11s0f0np0`, `enp11s0f1np1`, `enxc65a06c6ae7e` -> `br1` |
| BIOS SKU confirmed (B650D4U-2L2T/BCM) | _TBD_ |
| Physical cable in port (LAN1-4 silkscreen) | **LAN3** = np0 (direct AXE300 test) |
| Cable category (Cat5e/6/6a) | Cat6 ~3 ft (operator) |
| Switch/router port (AXE300 label) | **AXE300 10G LAN** (direct test) |
| np0 via Yuanley (prior) | **1000 Mb/s**; LED green flash then **orange**; partner **Not reported** |
| np0 direct AXE300 (2026-07-12) | **Speed: 10000Mb/s**, **Duplex: Full**, **Link detected: yes** |
| np1 via X540 daisy-chain (2026-07-12) | **Speed: 10000Mb/s**, **Link detected: yes** (`br1` + WOLF1 Network Bridge) |
| np0 Supported link modes includes `10000baseT/Full` | **Yes** |
| np0 Link partner advertised modes | **Not reported** on Yuanley; not re-checked on direct AXE300 |
| np0 driver / firmware | `bnxt_en` / firmware `225.0.148.0/pkg 225.4.1.0` (bus `0000:0b:00.0`) |
| np1 `ethtool` Speed (was NFS on 2.5G) | Was **1000 Mb/s** on 2.5G switch; now **10000Mb/s** to X540 |
| `enp7s0` (i210) | In **`br1`** (2026-09-04); stale `.157/32` on member -- remove |
| `enp6s0` (i210 LAN1) | In **`br1`** (2026-09-04) |
| 10G LED color (np0) | **Green** on direct AXE300 (10G per ASRock manual); was orange on Yuanley |
| 10G switch model | **Yuanley** 5-port full 10GbE; switching cap **100 Gbps**; packet forwarding **74.4 Mpps** |
| Phase A status | **Both BCM ports at 10G** via daisy-chain; hub **`br1`** (`hub`+`storage`); WOLF1 Network Bridge (`.92`) |
| hub UI / live aliases | **`br1`**: `hub/24` + **`storage/32`** (not two `/24`s — see [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md) br1 src bug) |
| Peak iperf to hub (same-L2 / `br1`) | **1.83 Gbps** `inference` -> `storage` (`-P 4`, 2026-07-13); single-stream `apps` -> `hub` ~940 Mbps |

### Root cause (isolated 2026-07-12)

| Test | Speed | Conclusion |
|------|-------|------------|
| np0 -> **Yuanley** (any port tried) | 1000 Mb/s | Switch port, **hub patch cable**, or AXE300-Yuanley uplink suspect |
| np0 -> **AXE300 10G** direct | **10000 Mb/s** | **BCM LAN3, driver, and np0 cable are good** |

**Not the cause:** i210 ports populated, BCM lacking 10G modes. (Jul 2026 triple-NIC IP layout was superseded by `br1` -- see 2026-09-04 SSoT.)

**Production restore (operator, one change at a time):**

1. Keep the **same cable** that just did 10G to AXE300; plug np0 into **Yuanley** (AXE300 still direct or restore AXE300 uplink separately).
2. If **1G on Yuanley** with same cable -> bad **Yuanley port** or switch; try another port or replace **hub-Yuanley** patch cable.
3. If **10G on Yuanley** -> restore **AXE300 -> Yuanley** uplink; re-check np0 speed (uplink cable may have been the weak link).
4. Optional PHY check: **np1** on Yuanley 10G port with `ethtool enp11s0f1np1` if np0 port on switch stays stubborn.

Do **not** force speed with undocumented `ethtool -s`. Broadcom / bnxt: **10GBASE-T must autoneg**; forced 10G is rejected ([bnxt README](https://github.com/ubports/ubuntu_kernel_xenial/blob/master/ubuntu/bnxt/README.TXT), [Broadcom AN](https://techdocs.broadcom.com/us/en/storage-and-ethernet-connectivity/ethernet-nic-controllers/bcm957xxx/adapters/Configuration-adapter/auto-negotiation-configuration.html)).

### Research deep-dive (2026-07-12) -- BIOS / IPMI / forums

**Agents:** ASRock+Broadcom manuals; forum/Reddit/STH/hub/Proxmox scan for "10G to router, 1G to switch, Intel OK."

| Claim | Official verdict |
|-------|------------------|
| Board "senses" switch vs router | **Not in any manual** -- different partners complete AN differently |
| **LAN3 "shared NIC"** | **BMC NC-SI** sideband ([manual](https://download.asrock.com/Manual/B650D4U-2L2TBCM.pdf)); dedicated IPMI is separate RTL8211F |
| BMC forces copper PHY to 1G | **Official docs silent** -- Keep Share NIC UP only keeps PHY up across reset ([FAQ](https://www.asrockrack.com/support/faq.asp?id=51)) |
| Empty i210 ports needed for 10G | **Official docs silent** (rumor) |
| Exact forum twin of our symptom | **Not found** |
| Closest forum pattern | Switch/PHY **interop** with BCM57416; Intel more tolerant ([Experts Exchange](https://www.experts-exchange.com/questions/29215297/Connecting-10Gb-NIC-to-1Gb-LAN-Copper-Supermicro-server.html)); Proxmox ASRock BCM threads are mostly **link down / FW / heat**, not stable 1G |

**Live control (same day):** `.92` Intel X540 on Yuanley = **10 Gbps**; `hub` BCM via Yuanley = **1 Gbps**; BCM direct to AXE300 = **10 Gbps**.

**One BIOS/HII setting worth trying (documented):** Broadcom HII **Energy Efficient Ethernet = Disabled** (10GBASE-T only) -- [Broadcom UEFI HII](https://techdocs.broadcom.com/us/en/storage-and-ethernet-connectivity/ethernet-nic-controllers/bcm957xxx/adapters/installation/uefi-hii-menu.html). OS equivalent: `ethtool --show-eee` / `ethtool --set-eee IFACE eee off` ([ethtool(8)](https://man7.org/linux/man-pages/man8/ethtool.8.html)). EEE is a weak match for "settles at 1G" but is the only Broadcom copper knob that is official and reversible.

**Also documented:** Prefer **LAN4** for host data if testing BMC share-path theory (manual labels only LAN3 as shared NIC). BIOS Chipset **OnBoard Broadcom Lan = Enabled**.

**Ranked root cause after research:** **BCM57416 <-> Yuanley 10GBASE-T autoneg interop** (not motherboard software sensing). Cable second if LEDs followed the patch on swap. BIOS/IPMI third.

**Daisy-chain option (operator exploring):** AXE300 has one 10G port — share it via `hub` + `.92` second ports + software bridge. Phase 1 (92A/92B only): [WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md).

### Cable map (post-cabinet-move 2026-07-27 — operator intent)

**Authoritative diagram:** [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md).

| BCM / i210 | Role (intent) | Cable destination |
|------------|---------------|-------------------|
| One BCM 10G | Uplink via WOLF1 bridge | **92B** (X540) |
| Other BCM 10G | Cabinet / `inference` USB path | **`inference` USB Ethernet** (NFS VIP `storage` is on **`br1`**, not a separate PHY) |
| i210 1G | Peer | **`inference` motherboard `eno1`** |
| i210 1G | Peer | **`hypervisor` USB** (port-count conflict if both `hypervisor` USBs claim i210 -- see cabinet map) |

```
AXE300 10G --> Yuanley --> 92A --[WOLF1 Network Bridge]-- 92B --> hub BCM
hub other BCM (br1 L2 member; storage VIP is on br1) --> inference USB
hub i210 1G --> inference eno1 (+ hypervisor USBs per resolved mapping)
AXE300 1G --> secondary USB
```
(92A → Yuanley, 92B → `hub` after operator swap 2026-07-27 -- see [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md).)

**Live 2026-07-27 from `orchestrator`:** ping `hub` OK; `storage` / `inference` / `hypervisor` / `secondary` FAIL until hub bridge includes cabinet-facing members.

### Cable map (historical 2026-07-12)

| BCM port | Linux iface | IP | Cable destination | Evidence |
|----------|-------------|-----|-------------------|----------|
| **LAN3** (unplug test) | `enp11s0f0np0` | `hub` mgmt | **Yuanley 10G switch** (confirmed -- unplug dropped SSH) | Operator unplug test |
| **LAN4** | `enp11s0f1np1` | L2 member of `br1` (`storage` on bridge, not np1) | **2.5G switch** (historical) | Operator confirmed 2026-07-12 |

```
Historical:
  AXE300 (10G) --> [Yuanley 5-port 10GbE]
                      |-- .92 (10G)
                      |-- hub np0 / LAN3
                      |-- [2.5G switch] --> hub np1 / LAN4 (storage), inference, hypervisor
```

### Does BCM np1 support 2.5G?

**No** -- per Step 3/5 `ethtool`, both BCM ports advertise only **`1000baseT/Full`** and **`10000baseT/Full`**. No `2500baseT` or `5000baseT` modes. A **2.5G switch port** therefore negotiates **1 GbE** with the BCM (not 2.5G).

i210 (`enp6s0` / `enp7s0`) is **1G hardware max** -- both are `br1` members (2026-09-04). Stale `.157/32` on `enp7s0` should be removed.

---

## Phase A investigation runbook

**Who:** operator on `hub` (`operator`). **One command per step** when interactive.
**STOP:** access denied; no `10000baseT/Full` in supported modes; still 1000 Mb/s after `-r` with 10G advertised -- ask cable/switch port; do not invent advertise masks or empty-port workarounds.

### Step 1 -- Link inventory

**From `hub` (hub shell as `operator`):**

```bash
ip -br link
```

### Step 2 -- Address inventory

```bash
ip -br addr
```

### Step 3 -- np0 link details

```bash
sudo ethtool enp11s0f0np0
```

### Step 4 -- np0 driver

```bash
sudo ethtool -i enp11s0f0np0
```

### Step 5 -- np1 (if present)

```bash
sudo ethtool enp11s0f1np1
```

```bash
sudo ethtool -i enp11s0f1np1
```

### Step 6 -- i210 ports (replace `IFACE` from Step 1)

```bash
sudo ethtool IFACE
```

### Step 7 -- Restart autoneg on np0

Per [ethtool(8) `-r`](https://man7.org/linux/man-pages/man8/ethtool.8.html):

```bash
sudo ethtool -r enp11s0f0np0
```

### Step 8 -- Re-read Speed

```bash
sudo ethtool enp11s0f0np0 | grep -E 'Speed|Duplex|Supported link|Advertised link|Link detected'
```

### Step 9 -- Physical LED

Note rear-panel 10G LED on the cabled BCM port: **Green = 10G**, **Orange = 1G** (ASRock manual).

### Step 10 -- hub UI

System -> Network -> Interfaces: record link speed and alias bindings. Use **Test Changes** (60 s) if editing ([Configuring Interfaces](https://www.hub.com/docs/scale/network/interfaces/configuringinterfaces/)).

### Step 11 -- Inventory script

```bash
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/lan-bandwidth-inventory.sh
```

(Path assumes hub clone; adjust if repo lives elsewhere.)

---

## Success criteria (Phase A complete)

- [x] `ethtool` reports **Speed: 10000Mb/s** on BCM uplink (**direct AXE300**, 2026-07-12)
- [ ] Same speed on **production topology** (np0 via Yuanley with AXE300 uplink restored)
- [x] 10G LED **Green** on BCM port (direct AXE300)
- [x] Live evidence table filled and dated
- [x] Silkscreen LAN3 = `enp11s0f0np0`; LAN4 = `enp11s0f1np1`
- [x] No hub IP/bond mutation in first pass

**Blocked on production path:** Yuanley hop still at 1G until port/cable/uplink isolation completes.

---

## Forbidden in Phase A

- Uncabling i210 ports based on rumor
- Recreating retired `br0` bridge
- LACP across `hub`/`storage` aliases on `br1` (same bridge)
- IPv4 on `br1` member ports (Post Init must not assign `storage` to np1 or `.157` to `enp7s0`)
- Undocumented `ethtool -s` speed forcing
- Agent SSH to `hub` (operator paste only)

---

## After Phase A (operator decision only)

| Outcome | Next step (official) |
|---------|---------------------|
| 10G negotiated | Re-run iperf matrix; update [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md) results |
| Stuck at 1G | Reseat cable; confirm AXE300 10G port; BIOS OnBoard Broadcom Lan enabled |
| Cable second BCM port (np1) | Operator cables LAN4; hub UI bind per official docs; **no** `br0` |

LACP on np0+np1 requires switch **IEEE 802.3ad** and hub Link Aggregation UI with **no standalone IP on member ports** -- deferred until separate operator confirmation.

---

## Related

- [LAN_BANDWIDTH_UTILIZATION.md](LAN_BANDWIDTH_UTILIZATION.md) -- cluster utilization SSoT
- [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md) -- iperf procedures
- [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md) -- IP map and matrix
- [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) -- brain operator guide
- `scripts/lan-bandwidth-inventory.sh`
