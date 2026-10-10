# Cluster idle power (always-on hosts)

**Goal:** cut idle watts on **`hub`**, **`inference`**, and **`hypervisor`** without capping
load performance (no GPU `-pl`, no CPU max-freq clamp). Fan curves stay later.

**Policy:** Hardware P-states and HWP Energy Performance Preference (EPP) may
drop clocks at idle. Under load, firmware still ramps to the same turbo / GPU
P0 path.

---

## Official manuals

| Topic | Source |
|-------|--------|
| `intel_pstate` governors and HWP EPP | [Kernel intel_pstate](https://docs.kernel.org/admin-guide/pm/intel_pstate.html) |
| `performance` + HWP locks EPP to 0 (max P-state) | Same page: HWP + `performance` |
| `cpupower frequency-set -g` | [Debian `cpupower-frequency-set(1)`](https://manpages.debian.org/bookworm/linux-cpupower/cpupower-frequency-set.1.en.html) |
| systemd `Type=oneshot` + `RemainAfterExit=` | [systemd.service(5)](https://man7.org/linux/man-pages/man5/systemd.service.5.html) |
| NVIDIA idle P-states / persistence | [nvidia-smi](https://docs.nvidia.com/deploy/nvidia-smi/) |
| hub 25.04 HDD Standby / APM | [Disks screen](https://www.hub.com/docs/scale/25.04/scaleuireference/storage/disksscreen/) |
| smartd skip spun-down disks | Debian [`smartd.conf(5)` `-n standby`](https://manpages.debian.org/bookworm/smartmontools/smartd.conf.5.en.html) |
| hub Apps docker data-root | [App storage](https://apps.hub.com/getting-started/app-storage/) |

---

## `inference` (ai-148) -- already aligned

- **Disk:** Samsung 990 PRO 1 TB NVMe only (no HDDs).
- **CPU:** `intel_pstate`, governor **`powersave`**, EPP **`balance_performance`**.
- **GPUs (inference `rpc-server` resident):** idle P8 on the order of **~8--11 W**
  each. Leave NVIDIA power limits at default. Do not set `nvidia-smi -pl`.

No CPU governor change on this host.

---

## `hypervisor` (pve-i5 / Proxmox) -- CPU governor

**Hardware:** i5-9600K, Samsung 990 PRO NVMe only. 1660 Super is **vfio-pci**
into VM 100; guest idle is already P8 (~13 W). Do not change GPU power limits.

**Problem:** host `scaling_governor` was **`performance`**. With HWP that
**locks EPP to 0**, so the package stays at max P-state even at idle
([intel_pstate HWP](https://docs.kernel.org/admin-guide/pm/intel_pstate.html)).
sysfs EPP writes are rejected until the governor is **`powersave`**.

**Intended state (match `inference` HWP hint):**

1. `scaling_governor=powersave` on every CPU
2. `energy_performance_preference=balance_performance` (HWP still turbo under load)

**Persist:** `hypervisor` has no `linux-cpupower` / `cpufrequtils` package. Do **not**
`apt install` from the public internet on this host. Use a systemd oneshot that
writes the same sysfs nodes the kernel documents.

Unit and script in git:

- [deploy/cluster-members/hypervisor/alfa-cpu-powersave.sh](../deploy/cluster-members/hypervisor/alfa-cpu-powersave.sh)
- [deploy/cluster-members/hypervisor/alfa-cpu-powersave.service](../deploy/cluster-members/hypervisor/alfa-cpu-powersave.service)

Install from `orchestrator` (hypervisor has no alfa-ai clone): copy those two files to
`/usr/local/sbin/alfa-cpu-powersave.sh` and
`/etc/systemd/system/alfa-cpu-powersave.service`, then
`systemctl daemon-reload` and `systemctl enable --now alfa-cpu-powersave.service`.

**Applied 2026-09-02:** all 6 CPUs `powersave` / EPP `balance_performance`;
unit `enabled` + `active`. Package RAPL ~**8.7 W** over 2 s (was ~**15 W**
under `performance`). After a Proxmox reboot, run
[verify-alfa-cpu-powersave.sh](../deploy/cluster-members/hypervisor/verify-alfa-cpu-powersave.sh)
on the host.

**Not in scope here:** VM `onboot` for stopped guests (101 / 106); USB NIC
power; fan curves.

---

## `hub` (hub / hub 25.04) -- disks vs SSD

**Intended split:** `ssd` = high-cadence ALFa runtime (DBs, hot GGUF,
slot-cache). The backup liveness heartbeat moved to container **tmpfs**
(RAM), not SSD. **`HDDs` + `The_Biz`** keep hub seed,
Immich photos/videos, Jellyfin media, and other low-activity data.
Do **not** reinstall Immich/Jellyfin to Host Path for this work.
Procedure: [hub_111_ARCHIVE_VS_SSD.md](hub_111_ARCHIVE_VS_SSD.md).

**SSD first (already):** production GGUF is
`/mnt/ssd/Alfa-AI/llama-cpp/models/Qwen3.8-27B-Q8_0.gguf`. Postgres/Redis for
brain live under `/mnt/ssd/alfa-ai/` ([HUB_ARTIFACTS.md](HUB_ARTIFACTS.md)).
There is **no** `/mnt/nvme` data pool; boot NVMe is OS only.

**HDDs pool cannot fully spindown while Apps/brain run.** Docker root is
`ix-apps` on **HDDs** (`/mnt/.ix-apps/docker`). Overlay/txg keeps raidz2
members **active/idle**. Official Apps migrate would copy **Immich ixVolumes
too** (~401 G of ~633 G) onto `ssd` (does not fit; media stays on HDD by
policy). Do **not** hand-edit Docker `data-root`. Cut the **30 s** backup
heartbeat and slot-cache on HDD first -- that is unnecessary chatter, not
photo/Jellyfin traffic. The backup sidecar is a **separate compose project**:
a normal orchestrator stop/start does **not** recreate it (see
[hub_111_ARCHIVE_VS_SSD.md](hub_111_ARCHIVE_VS_SSD.md) Phase B).

**The_Biz** (second 5-disk raidz2) shows ~0 ZFS I/O but disks stay spinning.
`smartd` is **inactive**; live `smartd.conf` already has **`-n standby`**.
Tweaking SMART will not park those disks. Do **not** raise HDD Standby above
the current 10-minute timer as a substitute. Confirm Disks APM / Standby and
atime=off per the archive doc Phase A.

**GPU:** RTX 3050 idle P8 ~10 W with `rpc-server` resident -- leave `-pl` alone.

**Verdaccio** (`:4873`) crash-loop (2026-09) was bind-mount permissions, not HDD
I/O: `config.yaml` mode 660 and storage not owned by Docker uid **10001** /
gid **65533**. Live again after chmod + chown. See
[deploy/npm-proxy/README.md](../deploy/npm-proxy/README.md). It does not park
the HDDs pool.

---

## Related

AC for `hub` / `inference` / `hypervisor` is on the **KU** Renogy 2 kW (cargo trailer), not the T2 RV inverter.
EM16 A3 (do not add B2): **~279 W** on 11 Sep 16:11 with fan+Midea off; **~418 W** on 10 Sep 14:57 same mix; **~720 W** with HVAC+cluster. **15 Sep 15:53 A3 ~1190 W is Sungold AC-in, not cluster idle** -- do not use that shot for host watts. Snapshot math: victron
[SOLAR_POWER_BALANCE.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SOLAR_POWER_BALANCE.md).

## Forbidden (this policy)

- `nvidia-smi -pl` / persistence-mode experiments that fight inference
- Piecemeal inference shard/coordinator restart to "save GPU watts"
- hub Apps docker data-root hand-edit
- Migrating `ix-apps` onto `ssd` while Immich/Jellyfin ixVolumes are in that
  tree (capacity + would copy media onto SSD --
  [hub_111_ARCHIVE_VS_SSD.md](hub_111_ARCHIVE_VS_SSD.md))
