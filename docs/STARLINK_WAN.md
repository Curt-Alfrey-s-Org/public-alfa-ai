# Starlink WAN (WOLF1 / AXE300)

**SSoT for internet (WAN) on this LAN.** Cluster IPv4 stays `orchestrator/24` on Archer **AXE300** (`orchestrator`). Do **not** put AXE300 into Access Point mode to “fix” WAN — that drops router features ([TP-Link FAQ 2420](https://www.tp-link.com/us/support/faq/2420/)) and would steal DHCP from the cluster.

LAN hiccups vs WAN: ping `hub` &lt; 1 ms and 10G bridge are **not** this path. Default route on WOLF1 is **Network Bridge → `orchestrator`**.

---

## Live path (2026-09-01 `tracert -d 1.1.1.1` from WOLF1)

| Hop | Address | Role |
|-----|---------|------|
| 1 | `orchestrator` | AXE300 LAN gateway |
| 2 | `orchestrator` | Starlink router LAN |
| 3 | `100.64.0.1` | Starlink **CGNAT** (`100.64.0.0/10`) |

Hop 3 matches Starlink’s documented default IPv4: Carrier Grade NAT from **`100.64.0.0/10`** ([IP Address](https://starlink.com/mh/support/article/ac09301b-cef6-a125-c251-856196a77f92)). Hop 2 is a second private LAN in front of that (AXE300 WAN is on `orchestrator/24`). Starlink Help does **not** call this “double NAT”; TP-Link does ([FAQ 3113](https://www.tp-link.com/us/support/faq/3113/)).

**Observed (2026-08-31 speedtest behind AXE300):** ~37 Mb/s down, **~0.28 Mb/s up**, ~27 ms ping.

**Split-test (2026-09-01):** iPhone on **AXE300 Wi‑Fi** **97 down / 9 up** (in Starlink Standard expected upload **8–20 Mbps**, [DOC-1525](https://starlink.com/legal/documents/DOC-1525-57370-71)). Dish and AXE300 WAN are healthy.

| Client | Path | Upload (approx.) |
|--------|------|------------------|
| iPhone | AXE300 Wi‑Fi | **9 Mb/s** |
| `inference` | L2 through WOLF1 Network Bridge → Yuanley → AXE300 | **~2.8 Mb/s** (httpbin POST, before LSO change) |
| WOLF1 before LSO off | L3 on Network Bridge | **~0.6 Mb/s** (Cloudflare POST;  off unchanged) |
| WOLF1 after `Disable-NetAdapterLso` on Ethernet 4/5 | same | **~8.5–9.8 Mb/s** (Cloudflare `https://speed.cloudflare.com/__up`) |

Cause was **X540 Large Send Offload v2** on the Network Bridge members, not Starlink, , or router QoS. **Leave LSO off.** Both NICs report `IPv4Enabled`/`IPv6Enabled` **False**. Rollback: `Enable-NetAdapterLso` ([Disable-NetAdapterLso](https://learn.microsoft.com/en-us/powershell/module/netadapter/disable-netadapterlso)). Details: [WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md).

**HomeShield QoS (2026-09-01 live UI):** web header **AXE16000 Quad-Band Wi‑Fi 6E Router** (same hardware as Archer **AXE300** in [TP-Link UG](https://static.tp-link.com/upload/manual/2022/202211/20221102/1910013277_Archer%20AXE300_UG_REV1.0.0.pdf) §10.3). **Enable** was **unchecked**. Download/Upload fields showed 1000 Mbps each (ignored while QoS is off). Router QoS is **not** the WOLF1 upload cap.

Starlink **typical** upload is **5–20 Mbps**, not guaranteed; **can fall below those ranges** in peak congestion ([Service Plans PDF](https://api.starlink.com/public-files/Starlink%20Service%20Plans.pdf) footnote 1). Legal “Expected speeds per service plan” for **Standard (fixed)** upload is **8–20 Mbps** ([Specifications DOC-1525](https://starlink.com/legal/documents/DOC-1525-57370-71)). **0.28 Mb/s is far below those published bands.** Starlink does **not** document a numeric “floor.” Peak hours are typically **6pm–11pm local** ([Slow Speeds - Third-Party Router](https://starlink.com/support/article/ffb7b3ee-2a20-c0e0-4c60-003c8470e80d)).

---

## Official Starlink procedure for slow speeds with a third-party router

**Do this first.** Starlink’s article is [Slow Speeds - Third-Party Router](https://starlink.com/support/article/ffb7b3ee-2a20-c0e0-4c60-003c8470e80d):

1. **Remove all third-party hardware if possible** (here: take AXE300 out of the path) and run a speed test **during off-peak hours** using the **Starlink app and Starlink router**.
2. Compare to the **Expected Speeds Per Service Plan** chart (same article; table also in [DOC-1525](https://starlink.com/legal/documents/DOC-1525-57370-71)).
3. If results are **not** in range: **Contact Support** in the app, with screenshots and date/time of the tests.

Starlink also: **Check for Obstructions** in the app ([Standard kit setup](https://starlink.com/support/article/b20d296a-0857-27b3-239a-8569b658f138)). Obstructions can **lower throughput** ([Multiple Starlinks](https://starlink.com/support/article/b63139bb-11e9-6bb6-f408-4df5f00844b1)).

Starlink **does not guarantee** performance or compatibility with third-party networking devices (same Slow Speeds article). They do **not** document Bypass Mode as the cure for low upload.

---

## Bypass Mode (how Starlink attaches a third-party router)

Use after the official split-test if the **Starlink router** upload is in-range and Wolf1 behind AXE300 is still ~0.3 Mb/s.

Official:

- [What is Bypass mode?](https://www.starlink.com/support/article/a0fe8d51-32f7-d2b9-d74a-801e31ad9f6a)
- [Using a Third-Party Router with Starlink](https://starlink.com/support/article/0b372c01-c692-8920-8396-ffb7f429aab1)
- Gen 3 PDF: “In the Starlink app, bypass your Router. **Factory reset required to exit bypass mode.**” Violet LED = bypass. Paper-clip reset on the router ([Gen 3 Router Setup Guide](https://starlink.com/public-files/Gen3RouterSetupGuideStandardGen2.pdf)).
- Bypass is for **third-party routers** and provides **one IP**. Do **not** enable bypass to hang a **switch** on Standard Actuated (use the ethernet adapter; do not put a switch between power supply and router) ([network switch article](https://www.starlink.com/support/article/0fe26b2b-ffab-001c-e950-7a07f3082e5d)).

Keep AXE300 in **Router** mode and `orchestrator/24`. After bypass, AXE300 WAN should leave `orchestrator1.x` and receive Starlink’s default **CGNAT** address (`100.64.0.0/10`). Bypass does **not** grant a public IPv4; public IP is a **Priority** option ([IP Address](https://starlink.com/mh/support/article/ac09301b-cef6-a125-c251-856196a77f92)). Residential/Roam CGNAT session limit is **1,200** ([CGNAT session limits](https://starlink.com/en-kr/support/article/bb372afe-7dd4-ae54-a2af-29cf63d24ddf)).

TP-Link analogue (ISP-side bridge, keep LAN router as NAT): [FAQ 3113](https://www.tp-link.com/us/support/faq/3113/). That is TP-Link’s double-NAT FAQ, not Starlink’s slow-speed article.

QoS is **off** on this router (2026-09-01). WOLF1 WAN upload was fixed by leaving **LSO off** on Ethernet 4/5, not Access Point mode.

---

## Out of scope / do not

- Re-enable WOLF1 **Ethernet 2** or add a second default gateway.
- Switch AXE300 to **Access Point** (cluster DHCP/NAT live there) ([FAQ 2420](https://www.tp-link.com/us/support/faq/2420/)).
- Treat Bypass as removing **CGNAT** or unlocking inbound IPv4 ([IP Address](https://starlink.com/mh/support/article/ac09301b-cef6-a125-c251-856196a77f92)).
- Skip Starlink’s “remove third-party hardware / off-peak / app+router test” and jump to Bypass.

---

## Related

- [WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md)
- [LAN_OPERATOR_TROUBLESHOOTING.md](LAN_OPERATOR_TROUBLESHOOTING.md)
- [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md)
