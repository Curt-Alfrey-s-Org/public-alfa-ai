# Pi4 Victron edge operator (orchestrator)

Raspberry Pi 4 running **victron-ble2mqtt-integration** as the **Victron BLE
(and optional Sungold USB) radio**. Mosquitto and Home Assistant live on
**`apps`** — see [HOMEASSISTANT_105_OPERATOR.md](HOMEASSISTANT_105_OPERATOR.md).
**Not** a GPU/Petals worker.

## Agent SSH from `orchestrator` (Cursor)

| Item | Value |
|------|--------|
| Host | `pi4` or `orchestrator` |
| User | `operator` |
| Key | `%USERPROFILE%\.ssh\id_ed25519_93_223` |
| SSH config | `Host pi4` in `~/.ssh/config` on `orchestrator` |
| Sudo | `/etc/sudoers.d/90-operator` — `NOPASSWD:ALL` (same as VM110) |

### One-time key setup (`orchestrator`)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).
```

Install pubkey on Pi (from `orchestrator` after default key works, or on Pi after git pull):

```powershell
scp $env:USERPROFILE\.ssh\id_ed25519_93_223.pub pi4:/tmp/
ssh pi4 "grep -qxF \"\$(cat /tmp/id_ed25519_93_223.pub)\" ~/.ssh/authorized_keys || cat /tmp/id_ed25519_93_223.pub >> ~/.ssh/authorized_keys"
```

Or on Pi: `bash deploy/cluster-members/solar-broker/install-agent-ssh-from-93.sh`

### One-time passwordless sudo

Preferred (password once on TTY):

```powershell
ssh -t pi4 "bash -s" < C:/Users/operator\alfa-ai\deploy\cluster-members\solar-broker\install-passwordless-sudo.sh
```

Or on Pi console: `bash install-passwordless-sudo.sh`

Official validation: [visudo(8)](https://manpages.debian.org/bookworm/sudo/visudo.8.en.html),
[sudoers(5)](https://manpages.debian.org/bookworm/sudo/sudoers.5.en.html).

### Verify from `orchestrator`

```powershell
ssh pi4 "echo SSH_OK; whoami; hostname"
ssh pi4 "sudo -n true; sudo -n docker info >/dev/null; echo SUDO_OK"
```

## Repo clone paths

| Host | Path |
|------|------|
| `orchestrator` (dev) | `C:/Users/operator\victron-ble2mqtt-integration` |
| Pi4 (runtime) | `~/victron-ble2mqtt-integration` (after clone on Pi) |

Deploy runbook: victron repo `DEPLOY.md`.

## LAN address: `solar-broker` on Ethernet or Wi-Fi

Same design as Pi5: [PI_NET_EXCLUSIVE.md](PI_NET_EXCLUSIVE.md). Wired profile
`netplan-eth0`, Wi-Fi `netplan-wlan0-StarWarz2`, extra `StarWarz2` autoconnect
off. Gateway/DNS `orchestrator`.

Install (from an alfa-ai tree on the Pi, or after copy from `orchestrator`):

```bash
sudo bash deploy/cluster-members/solar-broker/install-net-exclusive.sh
sudo bash deploy/cluster-members/_common/net-exclusive/apply-static.sh
```

Wi-Fi profile id is `netplan-wlan0-StarWarz2` (Netplan+NM). Extra `StarWarz2`
profile is set `autoconnect no` so it does not race.

## Bluetooth (exclusive onboard HCI)

Victron Instant Readout owns Pi4 onboard Bluetooth (usually `hci0`). BlueZ allows
one `StartDiscovery` session per client per adapter
([org.bluez.Adapter](https://manpages.ubuntu.com/manpages/noble/man5/org.bluez.Adapter.5.html)).
Theengs Gateway documents `--adapter` / `--blacklist` but not sharing one adapter
with `victron_ble2mqtt` ([Theengs use](https://gateway.theengs.io/use/use.html)).

Pi4 Theengs stays **off** (`ENABLE_PI4_THEENGS=0`). After `git pull`,
`sudo bash scripts/deploy.sh` runs Compose
[`--profile solar-theengs down`](https://docs.docker.com/compose/how-tos/profiles/)
so a leftover `unless-stopped` gateway cannot return on reboot. House Theengs on
Pi5 is unchanged. Do not `docker compose up -d theengs-gateway` on Pi4 (Compose
auto-enables that profile). Solar-site Govee `CAAF6F` tiles stay Unknown until
cells are replaced; that is not a reason to share `hci0`.

## OS updates

Debian security updates: enable `unattended-upgrades` (no auto-reboot) per
[FLEET_OS_AND_APP_UPDATES.md](FLEET_OS_AND_APP_UPDATES.md). This host has no
alfa-ai clone; copy the overlay from that repo after pull on `orchestrator`.

## Related

- [HOMEASSISTANT_105_OPERATOR.md](HOMEASSISTANT_105_OPERATOR.md) — broker + HA on `apps`
- [RELATED_VICTRON_HOMEAUTO.md](RELATED_VICTRON_HOMEAUTO.md)
- [NODE_INVENTORY.md](NODE_INVENTORY.md) — Pi4 row
- [victron docs/ALFA_CLUSTER_INTEGRATION.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/ALFA_CLUSTER_INTEGRATION.md)
- `deploy/cluster-members/solar-broker/` — agent SSH + sudo install scripts
- [PI_NET_EXCLUSIVE.md](PI_NET_EXCLUSIVE.md) — Ethernet/Wi-Fi exclusive static IP
- [PI5_OPERATOR.md](PI5_OPERATOR.md)
