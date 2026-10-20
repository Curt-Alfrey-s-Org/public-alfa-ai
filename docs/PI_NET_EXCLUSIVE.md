# Pi Ethernet / Wi-Fi exclusive static LAN (Pi4 `solar-broker`, Pi5 `edge`)

Both Raspberry Pi edge boards keep **one** IPv4 on whichever uplink is live.
Linux cannot put the same address on `eth0` and `wlan0` at once (ARP conflict).

| Host | Address | Wired profile | Wi-Fi profile |
|------|---------|---------------|---------------|
| Pi5 | `orchestrator/24` | `Wired connection 1` | `StarWarz2` |
| Pi4 | `orchestrator/24` | `netplan-eth0` | `netplan-wlan0-StarWarz2` |

Gateway / DNS: `orchestrator`. Ethernet metric `100`, Wi-Fi `600`.
A DHCP reservation is **one MAC → one IP**; do not try to reserve the same
address for both MACs. Keep the address out of the AXE300 DHCP pool.

| Wired carrier | Wi-Fi radio | Who owns the static address |
|---------------|-------------|------------------------------|
| present | off | `eth0` |
| absent | on, Wi-Fi profile activated | `wlan0` |

## Switcher: `alfa-net-exclusive.service`

Canonical scripts: `deploy/cluster-members/_common/net-exclusive/`.
Host defaults: `pi4-victron/alfa-net-exclusive.default`,
`pi5-240/alfa-net-exclusive.default` → `/etc/default/alfa-net-exclusive`.

The unit polls `/sys/class/net/eth0/carrier` (not `nmcli` "ethernet connected",
which also matches Docker veths). It never runs `nmcli connection down`:
[nmcli(1)](https://www.networkmanager.dev/docs/api/latest/nmcli.html) blocks
that profile from autoconnect until reboot, modify, or explicit `connection up`.

Dispatcher-only [Example 15](https://www.networkmanager.dev/docs/api/latest/nmcli-examples.html)
was not enough on Pi5 (radio on, profile stayed disconnected). Official limits:
[NetworkManager-dispatcher(8)](https://www.networkmanager.dev/docs/api/latest/NetworkManager-dispatcher.html),
[RFKill](https://networkmanager.dev/docs/rfkill/).
`ExecStopPost`: [systemd.service(5)](https://manpages.debian.org/bookworm/systemd/systemd.service.5.en.html).

Install on the Pi (copy this repo tree, then):

```bash
sudo bash deploy/cluster-members/solar-broker/install-net-exclusive.sh
# or
sudo bash deploy/cluster-members/edge-host/install-net-exclusive.sh
```

`ip link set eth0 down` is admin-down; replugging the cable does not undo it.
Use `ip link set eth0 up` or reboot. Do not drop `eth0` on a headless board
without `test-failover.sh`'s restore timer.

## Related

- [PI4_VICTRON_OPERATOR.md](PI4_VICTRON_OPERATOR.md)
- [PI5_OPERATOR.md](PI5_OPERATOR.md)
