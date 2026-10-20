# LAN island gateway outage (hub br1 without AXE300 path)

**Status:** Active incident class (observed **2026-09-24**).  
**Symptom:** Hosts on the **hub `br1` L2 island** can talk to **`hub` / `storage` / each other**, but **cannot ARP `orchestrator`**, reach **the public internet**, or resolve **`github.com`**. **WOLF1 (`orchestrator`)** on the **Yuanley / AXE300** path still reaches **`.1`** and the internet.

**Physical SSoT:** [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md) — `inference`, `apps` (via `hypervisor`), and cabinet cables through **`hub`** must have a **bridge member** with L2 to **92B / Yuanley / AXE300 `orchestrator`**.  
**hub bridge SSoT:** [hub_111_10G_NIC.md](hub_111_10G_NIC.md).

**DNS / gateway policy (all hosts):** resolver **`orchestrator` only**; AdGuard **`orchestrator`** only via AXE300 — [CLUSTER_DNS_AND_GATEWAY.md](CLUSTER_DNS_AND_GATEWAY.md).

**Official references:**

- hub bridge: https://www.hub.com/docs/scale/network/interfaces/settingupbridge/
- Linux ARP: https://man7.org/linux/man-pages/man7.arp.7.html
- Cloudflare tunnel errors (530): https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/troubleshoot-tunnels/

---

## What breaks

| Surface | On island hosts (`hub`, `apps`, `inference`, …) | Still OK on island |
|--------|---------------------------------------------|---------------------|
| **Default gateway** | `ping orchestrator` fails; `ip neigh` **INCOMPLETE** | — |
| **Internet / DNS** | `ping 1.1.1.1` fails; `host github.com` fails | — |
| **Cluster git (GitHub `origin`)** | `git fetch` fails | Hub **NFS** + **LAN git** (below) |
| **Cloudflare public sites on `apps`** | **HTTP 530** at edge; `cloudflared` QUIC timeout to `198.41.x.x` | Local WP/nginx (e.g. **`:8092`** example-site) |
| **Orchestrator stop/start** | Failed on `pool-opt-in` GitHub sync until hub fallback (fixed in repo) | SSH east–west to hub |

**Not broken:** WordPress/MySQL containers on `apps` (`alfa_*`, `example-site_*`), inference LAN RPC between island hosts, NFS **`orchestrator`**.

---

## Verify (any Linux host)

From a clone at `origin/main` (after pull):

```bash
bash deploy/cluster-members/_common/verify-lan-gateway-reachability.sh
```

**From `orchestrator` (PowerShell)** — compare router vs island:

```powershell
Test-Connection orchestrator -Count 1 -Quiet
Test-Connection hub -Count 1 -Quiet
Test-Connection apps -Count 1 -Quiet
```

If **`.1` OK from `orchestrator`** but **FAIL from `hub` / `apps` / `inference`**, treat as **island partition** (this doc), not a dead router.

**`apps` websites (local + tunnels):**

```bash
ssh operator@apps 'bash ~/alfa-ai/deploy/cluster-members/apps/verify-public-sites-lan.sh'
```

---

## Fix order (operator)

### 1. Restore L2 from hub `br1` to AXE300 (root fix)

1. hub UI: **Network** — confirm **`br1`** holds **`hub/24`** and **`storage/32`** only on the bridge (not on enslaved ports). See [hub_111_10G_NIC.md](hub_111_10G_NIC.md) cleanup.
2. **Cabling:** BCM **92B** path **WOLF1 `Ethernet 5` ↔ `hub` 10G** must be up; that leg must reach **Yuanley → AXE300 `.1`**. See [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md).
3. After link up, from **`hub` shell (`operator`)**:

```bash
ping -c2 orchestrator
ping -c2 1.1.1.1
host github.com
```

Do **not** point island hosts at **`orchestrator`** — retired; it may ICMP-reply but does not restore WAN (verified **2026-09-24** on `inference`).

### 2. LAN-only git (until GitHub works)

Script (hub-first): `deploy/cluster-members/_common/sync-git-origin-hub-lan.sh`

| Host | Clone path | Hub `file://` origin |
|------|------------|----------------------|
| **`inference`** | `/home/operator/alfa-ai` | `file:///mnt/cluster/repo/alfa-ai/.git` |
| **`pool-opt-in`** | `/home/operator/alfa-ai` | `file:///mnt/cluster/repo/alfa-ai/.git` |
| **`hub`** | `/mnt/HDDs/Alfa-AI/repo/alfa-ai` | `file:///mnt/HDDs/Alfa-AI/repo/alfa-ai/.git` |

**One-time manual (example `pool-opt-in`):**

```bash
cd ~/alfa-ai
git remote set-url origin file:///mnt/cluster/repo/alfa-ai/.git
bash deploy/cluster-members/_common/sync-git-origin-hub-lan.sh ~/alfa-ai
```

**After WAN returns**, restore GitHub remotes:

```bash
git remote set-url origin operator@example.com:example/alfa-ai.git
```

**Orchestrator (`orchestrator`):** `Invoke-AlfaAiCluster.ps1` calls `sync-git-origin-hub-lan.sh` on remotes. **Stop** uses **non-fatal** git sync so teardown proceeds if sync still fails.

**`hub`:** `operator-cluster-111.sh` `pull_repo` uses the same script; **`start-error-logs`** treats git failure as **WARN** (STEP 0 recorder only).

### 3. `inference` / `.147` dual-NIC (ARP flux on same `/24`)

Applied **2026-09-24** — USB data plane **`.147/32`**, mgmt **`bond0` `inference/24`**, policy table **101**, sysctls **`arp_ignore=1`**, **`arp_announce=2`**.

```bash
sudo bash ~/alfa-ai/deploy/cluster-members/inference-coordinator/setup-dual-ip-data-plane.sh
```

Docs: [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md), [AI148_NIC_MAX_USE.md](AI148_NIC_MAX_USE.md) (cabinet-move note: LACP-to-AXE300 superseded while cabled via `hub`).

### 4. Public websites on `apps` after gateway green

Stacks: **`alfaqd-website`** (`alfa-nginx`, `cf-alfa`) → **example.com**; **`example-site-perch`** (`example-site-nginx`, `cf-example-site`) → **example-siteperch.com**. See [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md).

When **`verify-lan-gateway-reachability.sh`** passes on `apps`:

1. Wait **2–3 minutes** for `cloudflared` to register.
2. If still **530**, restart tunnel containers via Dockge (`cf-alfa`, `cf-example-site`).
3. Public check from `orchestrator`:

```powershell
curl.exe -fsS -o NUL -w "%{http_code}\n" --max-time 15 https://www.example.com/
curl.exe -fsS -o NUL -w "%{http_code}\n" --max-time 15 https://example-siteperch.com/
```

**LAN-only example-site:** `http://apps/` (no Cloudflare).

---

## WOLF1 (`orchestrator`) notes (same week)

- **Windows OEM network reset** permuted **`Ethernet N` names** — use **MAC** SSoT: [WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md).
- **Production:** **`orchestrator/24` + gateway `.1` + DNS `.1` on Network Bridge** (10G X540); **Private** profile for LAN ping. **Realtek uncabled is OK** — not required for cluster ops.
- **Large Send Offload V2 (IPv4 and IPv6) Disabled** on both X540s while `orchestrator` stays on that bridge. Host uploads were about **0.5 Mb/s** with V2 enabled and **26 Mb/s** after disable (2026-10-02). Details: [WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md).
- **Wi-Fi `orchestrator`:** DNS **`.1` only** or disable Wi-Fi as **`operator`** — not **`edge` / 1.1.1.1** on the orchestrator host.
- **Intel X540** flaps / **`0x9F`** — `Repair-Wolf1NetworkStep01-NicPower.ps1` from an **elevated** Administrator window as **`operator`**. It can set PCIe ASPM off. The X540 "allow power-off" checkbox is not exposed while those ports are **Network Bridge** members (`MSPower_DeviceEnable` invalid object, `Get-NetAdapterPowerManagement` error 31). Do not remove them from the bridge to set that checkbox during normal use.
- **Cluster stop/start:** `Start-Stop-AlfaAi.ps1` from `orchestrator` only — [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md).

---

## Related docs

- [LAN_OPERATOR_TROUBLESHOOTING.md](LAN_OPERATOR_TROUBLESHOOTING.md)
- [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) — git sync + stop resilience
- [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md) — `apps` stacks (not cluster-managed)

---

## Changelog

| Date | Change |
|------|--------|
| **2026-10-02** | WOLF1: Large Send Offload V2 Disabled on both X540s (`orchestrator` bridge uploads). |
| **2026-09-24** | WOLF1 production = `orchestrator` on 10G bridge; Realtek optional; `Verify-Wolf1NetworkLayout.ps1` |
