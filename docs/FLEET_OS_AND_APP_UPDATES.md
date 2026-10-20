# Fleet OS and app updates (non-Windows)

**SSoT for Phase 2.** Windows hosts (`orchestrator` / `gaming-c` / `gaming-a` / `gaming-b`) are out of
scope. Do not invent a homegrown updater; use each vendor's documented path.

**Reboots that take down inference** (GPU shards, coordinator, brain) are **never**
automatic. Kernel or NVIDIA driver updates wait for a full
[CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) stop, then
reboot, then start.

---

## Official manuals

| OS / tool | Manual |
|-----------|--------|
| Ubuntu automatic security updates | [Automatic updates](https://ubuntu.com/server/docs/how-to/software/automatic-updates/) |
| Ubuntu `needrestart` drop-in | Same page, **Service restarts** -- add a file under `/etc/needrestart/conf.d/` rather than editing `needrestart.conf` |
| Debian periodic updates | [PeriodicUpdates](https://wiki.debian.org/PeriodicUpdates) |
| Proxmox VE | [System Software Updates](https://pve.proxmox.com/wiki/System_Software_Updates) -- `apt update` then **`apt full-upgrade`** (not `apt upgrade`) |
| hub SCALE 25.04 | [Updating hub](https://www.hub.com/docs/scale/25.04/scaletutorials/systemsettings/updatescale/) -- **system restarts after an upgrade**; export password secret seed |
| Docker Compose image pull | [`docker compose pull`](https://docs.docker.com/reference/cli/docker/compose/pull/) |
| Linux Mint Update Manager | [mintupdate](https://linuxmint-user-guide.readthedocs.io/en/latest/mintupdate.html) |

Do **not** use Watchtower or other third-party image watchers. Docker's documented
refresh is `docker compose pull` then a controlled `up` -- and inference still
requires the orchestrator, not piecemeal container recreate.

---

## Policy (one path)

| Class | Hosts (live 2026-09-02) | Autonomous OS | App / container images |
|-------|-------------------------|---------------|-------------------------|
| **Ubuntu Server** | `inference`, `apps`, `pool-opt-in`, `monitor`, `rag` | **Yes -- already on.** `unattended-upgrades` daily, **security origins only**, `Automatic-Reboot` default **false**. Overlay [51alfa-unattended](../deploy/cluster-members/_common/apt/51alfa-unattended) pins reboot off and blacklists kernel / NVIDIA / docker prefixes. [50-alfa-list-only.conf](../deploy/cluster-members/_common/needrestart/50-alfa-list-only.conf) pins needrestart to **list-only**. | **Not silent.** Hub-first `docker compose pull` after `git pull`; inference only via `Start-Stop-AlfaAi.ps1`. |
| **Debian (pi4)** | `solar-broker` | **Enable** Debian `unattended-upgrades` (security), same overlay, **no auto reboot**. | Victron stack: operator compose pull when changing images. |
| **Linux Mint desktop** | `secondary` | **Mint Update Manager**, not Ubuntu `unattended-upgrades`. Security automation only after Timeshift per Mint docs. **No auto kernel** (opt-in inference GPU shard). | Same as Ubuntu: no silent compose recreate. |
| **Proxmox VE** | `hypervisor` (`pve-i5`) | **No** `unattended-upgrades` (rolling Debian + PVE). Daily check already; install with GUI or `apt update` then `apt full-upgrade`. | N/A (hypervisor). |
| **hub SCALE** | `hub` | **No** apt unattended. UI **Apply Pending Update** when idle; **always restarts**. Export secret seed. Never apply during inference serving. | hub Apps catalog in the UI; alfa-ai compose stacks follow hub-first pull, not Apps auto-update of brain images. |
| **Ubuntu VMs powered off** | `market`, `atems`, `probilliards` | Same Ubuntu overlay **when they are on**. | Same. |

Windows: Windows Update stays operator-owned; not this doc.

---

## Live inventory (2026-09-02)

Read-only helper: [report-unattended-upgrades.py](../deploy/cluster-members/_common/report-unattended-upgrades.py).

| Host | OS | `unattended-upgrades` | Notes |
|------|----|------------------------|-------|
| `inference` ai-148 | Ubuntu 26.04.1 | installed, `20auto-upgrades` = 1, timers enabled | Log shows daily security run; `-updates` pocket **commented** (Ubuntu default). `needrestart` `$nrconf{restart}` still commented `'i'` (list-only under unattended until overlay pins `'l'`). |
| `apps` web-sites | Ubuntu 26.04.1 | same | Apps host. |
| `pool-opt-in` | Ubuntu 26.04.1 | same | inference shard. |
| `monitor` | Ubuntu 26.04.1 | same | Monitoring. |
| `rag` | Ubuntu 26.04.1 | same | CPU RAG. |
| `hypervisor` pve-i5 | Debian 13 / PVE | **not installed** | Keep it that way. |
| `secondary` Nickey-Nakita | Linux Mint 22.3 | **not installed** | Use mintupdate, not apt UU. |
| `solar-broker` pi4 | Debian 13 | **installed 2026-09-02** (enable script + overlay) | Victron edge; needrestart list-only drop-in. |
| `hub` | hub 25.04 | N/A | Operator Update screen. |
| `market` / `atems` / `probilliards` | -- | unreachable | Powered off. |

---

## Ubuntu / Debian overlay (explicit)

Vendor default already installs **security** updates only and does **not**
auto-reboot ([Ubuntu Automatic-Reboot default false](https://ubuntu.com/server/docs/how-to/software/automatic-updates/)).
The overlay makes that policy **visible** and keeps docker / NVIDIA / kernel
packages off the unattended path.

Ubuntu 24.04+ documentation says `needrestart` may restart affected services
automatically. Vendor `needrestart.conf` on this fleet still comments
`$nrconf{restart} = 'i'` (interactive, which falls back to list-only when
unattended). The drop-in **pins `'l'`** so a future package default of `'a'`
cannot restart production units.

On a host that already has an **alfa-ai** clone (after `git pull`):

```bash
sudo bash deploy/cluster-members/_common/install-alfa-unattended-policy.sh
```

Debian hosts that lack the package (`solar-broker`) first:

```bash
sudo bash deploy/cluster-members/_common/enable-debian-unattended-upgrades.sh
```

Then the overlay script. `solar-broker` has no alfa-ai clone -- copy the two drop-in
files from this repo (or run the scripts from a checkout on `orchestrator` via SSH).

Do **not** uncomment `"${distro_id}:${distro_codename}-updates"` unless the
operator explicitly wants non-security packages unattended.

---

## Kernel / NVIDIA / Docker upgrades (manual)

1. Operator: `Start-Stop-AlfaAi.ps1 stop`
2. Apply `apt` / Mint / hub update on that host
3. Reboot if the vendor says a reboot is required
4. Operator: `Start-Stop-AlfaAi.ps1 start`

Never `apt upgrade docker-ce` or NVIDIA while the coordinator holds RPC sessions.

---

## Ubuntu fleet from `orchestrator` (Proxmox VMs + ai-148)

From **`orchestrator` (operator)** one orchestrated pass: agent SSH keys, GitHub identity
(staged from **`operator@apps`** `~/.ssh/id_ed25519` to operator hosts as
`~/.ssh/id_ed25519_github`), `git pull`, unattended policy, and `apt full-upgrade`:

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\orchestrator\Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).
```

Single host (example **`inference`** hub after `git push`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\deploy\cluster-members\orchestrator\Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md). `
  -HostIds 148
```

**Hosts:** Proxmox **100 / 102 / 103 / 105 / 106 / 107 / 109 / 110** and
**ai-148** (`operator@orchestrator`, inference GPU shards). Dedicated agent keys on
`orchestrator`: `id_ed25519_93_100`, `_102`, `_103`, `_105`, `_106`, `_107`, `_109`,
`_110`, `_148` (Ensure-SshKey scripts under `deploy/cluster-members/orchestrator/`).
Public halves live next to each member `install-agent-ssh-from-93.sh`. Manual
GitHub copy on a single VM:
`deploy/cluster-members/_common/install-github-ssh-from-105.sh` (requires scp
to `apps`, or use the `orchestrator` orchestrator relay).

**`inference` apt:** NVIDIA, Docker, and kernel upgrades require
[CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) **stop** before
`full-upgrade` while inference rpc containers are up. The orchestrator skips apt on
`inference` when llamacpp/rpc containers are running unless **`-ForceAptOn148`** (use
only after stop).

Phased Ubuntu packages may remain listed in `apt list --upgradable` until the
vendor rolls them out fleet-wide; that is not a failed `full-upgrade`.

---

## App (container) updates

1. Images **>= 100 MB**: seed or publish on `hub` first ([HUB_ARTIFACTS.md](HUB_ARTIFACTS.md)).
2. `git pull --ff-only` on the host that will recreate.
3. `docker compose pull` for **named** stacks that are **not** inference shards/coordinator.
4. Recreate with the stack's documented wait helper.
5. inference: orchestrator only.

Ask ALFa may **propose** a `run_command` pull; Approve is L2 every time.

---

## Related

- [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md)
- [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md)
- [AI_AUTONOMY_AND_OVERSIGHT.md](AI_AUTONOMY_AND_OVERSIGHT.md)
- [REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md)
- [PI4_VICTRON_OPERATOR.md](PI4_VICTRON_OPERATOR.md)
