# Pi5 edge operator (`orchestrator`)

Raspberry Pi 5 Model B Rev 1.1 (Debian 12 Bookworm, NetworkManager).
Victron / house-edge companion to [PI4_VICTRON_OPERATOR.md](PI4_VICTRON_OPERATOR.md).
Theengs publishes to Mosquitto on **`apps:1883`** ([HOMEASSISTANT_105_OPERATOR.md](HOMEASSISTANT_105_OPERATOR.md)).
**Not** a GPU / inference node.

## LAN address: `edge` on Ethernet or Wi-Fi

The host answers **`orchestrator/24`** on whichever uplink is live. Two
interfaces cannot hold that address at once, so the links are kept mutually
exclusive:

| Wired carrier | Wi-Fi radio | Owner of `orchestrator` |
|---------------|-------------|---------------------------|
| present | off | `eth0` (metric 100) |
| absent | on, `StarWarz2` active | `wlan0` (metric 600) |

Both profiles are static (`ipv4.method manual`, address `orchestrator/24`,
gateway/DNS `orchestrator`). No DHCP, so the router never leases `edge` — and a
DHCP reservation could not cover both MACs anyway (one reservation is one MAC).
Keep `edge` out of the AXE300 DHCP pool so nothing else takes it.

| Link | Profile | MAC (live 2026-09-03) |
|------|---------|------------------------|
| `eth0` | `Wired connection 1` | `2c:cf:67:ae:43:ec` |
| `wlan0` | `StarWarz2` | `2c:cf:67:ae:43:ed` |

### Who switches it: `alfa-net-exclusive.service`

Canonical design (Pi4 and Pi5): [PI_NET_EXCLUSIVE.md](PI_NET_EXCLUSIVE.md).
Scripts live in `deploy/cluster-members/_common/net-exclusive/`; this host's
defaults are `deploy/cluster-members/edge-host/alfa-net-exclusive.default`.

**Why a reconcile loop and not only the NetworkManager dispatcher.** The
documented dispatcher recipe ([nmcli-examples Example 15](https://www.networkmanager.dev/docs/api/latest/nmcli-examples.html))
toggles the radio on wired up/down. On this board that was verified to enable
the radio on carrier loss but leave `wlan0` sitting in `disconnected`, so the Pi
went unreachable with the cable out. Three failure modes the loop covers:

1. **Autoconnect blocked.** After a manual `nmcli connection down`,
   NetworkManager will not auto-reactivate that profile, so radio-on alone never
   brings the link up. The loop activates the profile explicitly.
2. **Boot with no cable.** `WirelessEnabled=false` persists in
   `/var/lib/NetworkManager/NetworkManager.state` ([RFKill](https://networkmanager.dev/docs/rfkill/)),
   and no wired up/down event fires at boot when no cable was ever attached.
3. **Dispatcher killed.** Dispatcher scripts "will be killed if they run for too
   long" ([NetworkManager-dispatcher(8)](https://www.networkmanager.dev/docs/api/latest/NetworkManager-dispatcher.html)).

The unit is `Restart=always`. `ExecStopPost` runs
`alfa-net-exclusive-stop.sh`: if `eth0` still has carrier, Wi-Fi stays off
(avoids a duplicate `edge` on restart); if carrier is absent, it enables the
radio and runs `nmcli connection up StarWarz2` ([nmcli(1) `connection up`](https://www.networkmanager.dev/docs/api/latest/nmcli.html)).
[`systemd.service(5)` `ExecStopPost`](https://manpages.debian.org/bookworm/systemd/systemd.service.5.en.html).

Overrides go in `/etc/default/alfa-net-exclusive` (`WIFI_CON`, `POLL_SEC`, ...).

### Install (on the Pi)

Copy `deploy/cluster-members/edge-host/` onto the Pi, then:

```bash
sudo bash deploy/cluster-members/edge-host/install-net-exclusive.sh
```

The installer reads `alfa-net-exclusive.sh`, `alfa-net-exclusive-stop.sh`, and
`alfa-net-exclusive.service` from the same directory as the install script
(override with `SRC=`). It removes
`/etc/NetworkManager/dispatcher.d/70-wifi-wired-exclusive.sh` if present.

### Verified failover (2026-09-03)

Carrier dropped at 14:21:30 → radio enabled → `StarWarz2` activated 14:21:36
(`edge` on `wlan0`, default route metric 600). Carrier restored 14:23:27 → radio
disabled, `edge` back on `eth0`. Round trip under 10 s each way.

`ip link set eth0 down` is an **admin-down**. Replugging the cable does **not**
bring that interface back; use `ip link set eth0 up` or reboot. The 90-second
timer in `test-failover.sh` exists for that reason. Do not drop `eth0` without it.

### Operator scripts

From a clone of this repo on the Pi (paths relative to the alfa-ai root):

| Task | Command |
|------|---------|
| Diagnose | `sudo bash deploy/cluster-members/edge-host/diag-net-240.sh` |
| Re-apply static addressing | `sudo bash deploy/cluster-members/edge-host/apply-static-240.sh` |
| Install / repair the switcher | `sudo bash deploy/cluster-members/edge-host/install-net-exclusive.sh` |
| Prove Wi-Fi path without unplugging | `sudo bash deploy/cluster-members/edge-host/test-wifi-path.sh` (scratch `.241`) |
| Live failover test | `sudo bash deploy/cluster-members/edge-host/test-failover.sh` (auto-restores wired after 90 s) |

Raspberry Pi OS Bookworm networking is NetworkManager:
[Configuring networking](https://www.raspberrypi.com/documentation/computers/configuration.html#configuring-networking).

## Agent SSH from `orchestrator`

Same key as Pi4 until a dedicated `id_ed25519_93_240` exists.

```powershell
ssh -o BatchMode=yes -i $env:USERPROFILE\.ssh\id_ed25519_93_223 operator@orchestrator hostname
```

## Related

- [RELATED_VICTRON_HOMEAUTO.md](RELATED_VICTRON_HOMEAUTO.md)
- [NODE_INVENTORY.md](NODE_INVENTORY.md)
- Victron [PI5_HOUSE_EDGE.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/PI5_HOUSE_EDGE.md) — Theengs to `apps` Mosquitto; `deploy_pi5.sh` starts autoheal for AdGuard HTTP health. Official Theengs image has no HEALTHCHECK.
