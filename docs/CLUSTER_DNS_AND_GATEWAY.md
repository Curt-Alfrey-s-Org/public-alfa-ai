# Cluster DNS and default gateway (SSoT)

**Policy (operator 2026-09-24):** Every cluster host uses **one** LAN DNS path and **one** default gateway:

| Setting | Value | Notes |
|---------|--------|--------|
| **Default gateway** | **`orchestrator`** | TP-Link **AXE300** |
| **DNS (resolver)** | **`orchestrator` only** | No per-host **1.1.1.1**, **hub**, or **orchestrator** |
| **AdGuard / filtering** | **`orchestrator`** | Configured **on the AXE300** (DHCP DNS or upstream), not duplicated on each OS |

**Why:** Split DNS (public resolvers on some hosts, router on others) hides outages and breaks cluster parity. AdGuard on **`edge`** remains the LAN filter when the **router** points clients at **`.1`** and the router forwards to **`edge`**.

**Official:** hub [Global Configuration](https://www.hub.com/docs/scale/core/configure/network/globalconfiguration/); Windows [Set-DnsClientServerAddress](https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientserveraddress); Linux netplan `nameservers.addresses` ([netplan.io](https://netplan.io/reference/)).

---

## Per-host checklist

| Host | Gateway | DNS | Do not use |
|------|---------|-----|------------|
| **`orchestrator` WOLF1** | **`.1`** on **Ethernet 2** (`orchestrator/24`) | **`.1`** only | Second default on **Network Bridge** / **Ethernet 5**; **`.173`** gateway |
| **`hub` hub** | **`.1`** | **`.1`** only (Global Configuration) | **1.1.1.1**, **hub**, **`edge`** in hub nameserver fields |
| **`apps` / `pool-opt-in` VMs** | **`.1`** via Proxmox / netplan | **`.1`** only | Extra `/etc/resolv.conf` forwarders |
| **`inference` ai-148** | **`.1`** on **`bond0`** | **`.1`** only in netplan | **`.173`**; public DNS in `resolv.conf` |
| **Gaming workers** | **`.1`** | **`.1`** only | — |

**Retired gateway/DNS IPs:** **`orchestrator`**, **`orchestrator`** — not gateway, not DNS ([PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md)).

---

## WOLF1 (`orchestrator`) after Windows network reset

**Cluster IP stays on Realtek `Ethernet 2` → `orchestrator/24`, gateway `orchestrator`.**

If **Intel X540 `Ethernet 5`** (or bridge) picked up **`orchestrator`** and gateway **`orchestrator`**:

1. **Do not** use **`.11`** or **`.173`** as default route for cluster/orchestrator traffic.
2. Either **disable DHCP** on the second NIC (cabinet/10G leg only), or leave it unplugged until cabling is verified.
3. **Do not** recreate **Network Bridge** with its **own** default gateway ([WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md)).

Verify from **`orchestrator` (PowerShell as `operator`)**:

```powershell
Get-NetIPConfiguration -InterfaceAlias 'Ethernet 2' | Select-Object InterfaceAlias,IPv4Address,IPv4DefaultGateway
Get-DnsClientServerAddress -InterfaceAlias 'Ethernet 2' -AddressFamily IPv4
```

Expected: address **orchestrator**, gateway **orchestrator**, DNS **orchestrator** only.

---

## Related

- [LAN_ISLAND_GATEWAY_OUTAGE.md](LAN_ISLAND_GATEWAY_OUTAGE.md) — when **`.1`** is unreachable from **`hub` island** but OK from **`orchestrator`**
- [hub_111_10G_NIC.md](hub_111_10G_NIC.md) — **br1** UI target for screenshot compare
- [CLUSTER_CABINET_CABLE_MAP.md](CLUSTER_CABINET_CABLE_MAP.md) — **`storage`**, **`hypervisor`**, **`inference`**, **`.147`**

---

## IP roles (avoid confusing hub with `.147`)

| IP | Where it lives | hub? |
|----|----------------|----------|
| **`hub`** | **`br1`** mgmt | Yes |
| **`orchestrator`** | **`br1`** `/32` NFS VIP alias | Yes — **only on `br1`**, never on a bridge member NIC |
| **`orchestrator`** | **`inference` USB** data plane (`/32`) | **No** — fix on **ai-148** netplan, not hub UI |
| **`orchestrator`** | **Proxmox** host (`apps` hypervisor) | **No IP on hub** — reachability depends on **`br1`** member **`enp7s0`** / i210 cable to **`hypervisor`** |

Fixing **`br1`** + removing stale VIPs on member ports usually restores **`storage`** NFS and **`hypervisor`** / **`apps`** path together ([LAN_ISLAND_GATEWAY_OUTAGE.md](LAN_ISLAND_GATEWAY_OUTAGE.md)).
