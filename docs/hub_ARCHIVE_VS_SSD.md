# `hub` archive HDDs vs SSD runtime (hub 25.04)

**Goal:** stop **high, unnecessary** write/read chatter on the spinners.
Everyday ALFa runtime (Docker graph, brain DBs, hot GGUF, slot-cache,
heartbeat files) belongs on **`ssd`**. Hub seed, Immich photos/videos,
Jellyfin media, and other **low-cadence** archives stay on **`HDDs`** /
**`The_Biz`**.

This is the operator SSoT for that split. Hub seed policy is unchanged:
canonical blobs still land on HDD first ([HUB_ARTIFACTS.md](HUB_ARTIFACTS.md)).

**Out of scope (do not reinstall or relocate):** Immich and its library,
Jellyfin and its media, and any other low-activity catalog app whose data
is mostly cold. Those are not the 24/7 culprit. Do not spend a Host Path
project on them unless `ssd` capacity later forces a shrink of `ix-apps`.

---

## Official manuals

| Topic | Source |
|-------|--------|
| Apps pool on SSD; `ix-apps` hidden; do not modify | [App Storage](https://apps.hub.com/getting-started/app-storage/) |
| SSD recommended for Apps pool | [Initial Setup -- Choosing the Apps Pool](https://apps.hub.com/getting-started/initial-setup/) |
| **25.10+** Choose Pool **Migrate existing applications** (host paths not copied) | [25.10 Apps UI](https://www.hub.com/docs/scale/25.10/scaleuireference/apps/) |
| **25.04** Choose Pool / Unset Pool -- **no** migrate checkbox in this version's UI ref | [25.04 Apps UI](https://www.hub.com/docs/scale/25.04/scaleuireference/apps/) |
| Host Path vs ixVolume (ixVolume is for tests) | Same App Storage page; [Installing Apps](https://apps.hub.com/managing-apps/installing-apps/) |
| Immich seven datasets; Host Path at **install** time | [Immich Deployment](https://apps.hub.com/resources/deploy-immich/) |
| System dataset pool | [Advanced Settings -- Storage](https://www.hub.com/docs/scale/systemsettings/advanced/advancedsettings/) |
| HDD Standby / APM | [Disks screen (25.04)](https://www.hub.com/docs/scale/25.04/scaleuireference/storage/disksscreen/) |
| Dataset **Enable Atime** | [Datasets screens](https://www.hub.com/docs/scale/datasets/datasetsscreens/) |
| OpenZFS `atime=off` (no write on read) | [zfsprops(7) `atime`](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html) |
| Local ZFS replication (SSD snapshot -> HDD archive) | [Local replication (25.04)](https://www.hub.com/docs/scale/25.04/scaletutorials/dataprotection/replication/localreplicationscale/) |
| smartd `-n standby` (skip checks if already spun down) | Debian [`smartd.conf(5)`](https://manpages.debian.org/bookworm/smartmontools/smartd.conf.5.en.html) / [`smartctl(8) -n`](https://manpages.debian.org/bookworm/smartmontools/smartctl.8.en.html) |
| 25.04 SMART service Power Mode | [SMART service 25.04](https://www.hub.com/docs/scale/25.04/scaletutorials/systemsettings/services/smartservicesscale/) |
| 25.10: smartd UI removed; middleware polls SMART every 90 min | [25.10 version notes](https://www.hub.com/docs/scale/25.10/gettingstarted/versionnotes/) |
| Docker bind mounts vs named volumes (binds are outside `data-root`) | [Bind mounts](https://docs.docker.com/engine/storage/bind-mounts/), [volumes](https://docs.docker.com/engine/storage/volumes/) |
| overlay2: prefer fast storage / volumes for writes | [overlay2 driver](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/) |
| ZFS txg flush dirty data (default 5 s) | [zfs.4 `zfs_txg_timeout`](https://openzfs.github.io/openzfs-docs/man/v2.4/4/zfs.4.html) |

**Forbidden (not in those manuals):** editing Docker `data-root` /
`/etc/docker/daemon.json` on hub Apps; community middleware "spindown
patches"; SeaChest / vendor firmware tools unless you explicitly choose a
non-official path.

---

## Official feasibility (goal vs data loss)

The goal -- **SSD for everyday heavy read/write, spinners for archive/seed**
-- is what the vendors already recommend. It does **not** need a custom
Docker `data-root`, a new orchestrator, or unofficial SCALE patches.

| Piece of the goal | Official mechanism | Data-loss gate |
|-------------------|--------------------|----------------|
| Docker images / overlay / named volumes on SSD | hub **Apps pool** on `ssd`. iX: SSD for repeated read/writes ([Initial Setup](https://apps.hub.com/getting-started/initial-setup/)). Docker: SSDs faster than spinning disks; volumes for write-heavy work ([overlay2](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)). | **25.10+:** **Migrate existing applications** copies images + **ixVolumes only**. Host paths stay. ([Initial Setup](https://apps.hub.com/getting-started/initial-setup/); [Managing Installed Apps](https://apps.hub.com/managing-apps/managing-installed-apps/)). **25.04:** [Apps UI](https://www.hub.com/docs/scale/25.04/scaleuireference/apps/) has **Choose Pool** / **Unset Pool** only. Unset **turns the apps service off**. There is **no** documented in-place copy. Do not Unset as a migrate. |
| App data on the pool you choose (SSD vs HDD) | **Host Path** datasets, not ixVolume. ixVolume is for tests; host path is production ([App Storage](https://apps.hub.com/getting-started/app-storage/)). Docker bind mounts sit **outside** the graph ([bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)). | Edit cannot change storage **volume type** ([Managing Installed Apps](https://apps.hub.com/managing-apps/managing-installed-apps/)). Immich cannot change **storage paths** after install ([Immich](https://apps.hub.com/resources/deploy-immich/)). Postgres host path: **Automatic Permissions** on **empty** dirs only ([App Storage](https://apps.hub.com/getting-started/app-storage/)). |
| Archive / seed on `HDDs` / `The_Biz` | Leave hub blobs on HDD. Bind or Host Path those datasets. Nightly **local replication** SSD -> HDD, both **On this System** ([local replication](https://www.hub.com/docs/scale/25.04/scaletutorials/dataprotection/replication/localreplicationscale/)). | First replication can **delete existing destination snapshots** if none match -- back them up first (same page). Apps UI **cannot** backup/restore `ix-apps` as of 25.10.0 ([App Storage](https://apps.hub.com/getting-started/app-storage/)) -- use ZFS snapshots of the pool **before** any Apps move. |
| Fewer spinner cycles | **Storage -> Disks -> HDD Standby** (5--330 min) and optional APM Level 1 ([Disks 25.04](https://www.hub.com/docs/scale/25.04/scaleuireference/storage/disksscreen/)). `atime=off` cuts read-induced atime writes ([zfsprops](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html)). | Docs do **not** promise enterprise NAS HDDs honor APM. Standby needs inactivity. Do **not** modify `ix-apps` ([App Storage](https://apps.hub.com/getting-started/app-storage/)). Delete app **Remove iXVolumes** / **Force-remove** is irreversible ([Managing Installed Apps](https://apps.hub.com/managing-apps/managing-installed-apps/)). |

**Supported without inventing a wheel:** Host Path (or compose binds) for DBs
on `ssd` and media/hub on HDD; 25.10 Apps migrate of the graph; Disks
Standby after the HDD writers stop; ZFS local replication for archive
copies.

**Not vendor-supported (stop):** `daemon.json` `data-root` on SCALE Apps;
25.04 Unset+Choose as a copy; rsync of `/mnt/.ix-apps`. Immich/Jellyfin
path conversion is **not in this plan**.

---

## Target layout

Three pools, three jobs:

| Pool | Role | Typical mount | What belongs here |
|------|------|---------------|-------------------|
| **`ssd`** | High-cadence runtime | `/mnt/ssd` | hub **Apps pool** when it fits (`ix-apps` / Docker overlay), system dataset (already), ALFa Postgres/Redis, hot GGUF, RPC tarball, slot-cache, backup heartbeat |
| **`HDDs`** | Hub + media that is fine on rust | `/mnt/HDDs/Alfa-AI` | Canonical hub tree, NFS `/mnt/cluster` + SMB, Immich/Jellyfin **as they are today** (including ixVolumes if that is how they were installed) |
| **`The_Biz`** | Low-activity business/media | `/mnt/The_Biz` | Rarely-read shares. Park with Disks Standby. Not ALFa timers. |

**Rule of thumb:** if a process writes it every few **seconds or minutes**
while nobody is using the box, it must not live on a spinner. Browsing
photos, playing a movie, or a nightly dump is allowed on HDD.

**Docker (official):** named volumes and image layers live under Docker's
storage directory ([volumes](https://docs.docker.com/engine/storage/volumes/),
[daemon data-root](https://docs.docker.com/engine/daemon/)). **Bind mounts
do not** -- they use the host path you give
([bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)). That is
why ALFa Postgres **can** sit on `/mnt/ssd/...` even while `ix-apps` is still
on HDD. overlay2 docs say **SSDs provide faster reads and writes
than spinning disks** and to use volumes for write-heavy work
([overlay2](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)).
On SCALE, moving the graph still means moving **`ix-apps`**, not a hand-edited
`data-root`.

### Already on SSD (do not move back)

| Path / dataset | Why |
|----------------|-----|
| `ssd/.system` | System dataset (netdata, Samba metadata). Standard S2 in [HOST_STORAGE_AND_NETWORK_STANDARDS.md](HOST_STORAGE_AND_NETWORK_STANDARDS.md) |
| `/mnt/ssd/alfa-ai/{postgres,redis}` | Brain DB stacks (`ALFA_POSTGRES_DATA_PATH` / `ALFA_REDIS_DATA_PATH`) |
| `/mnt/ssd/Alfa-AI/llama-cpp/models/` | Hot 27B GGUF (`promote-gguf-to-ssd.sh`) |
| `/mnt/ssd/Alfa-AI/docker-images/` | Hot RPC image tarball |
| `/mnt/ssd/Alfa-AI/llama-cpp/slot-cache-111` | Coordinator KV slot cache (`SLOT_CACHE_DIR`; `default-slot-cache-dir-111.sh`) |

### High-cadence HDD writers (this is the work)

Last measured: `HDDs/ix-apps` ~633 G (Immich ixVolume ~401 G of that is
**cold media**; Docker graph ~230 G). Cold media does **not** keep raidz2
members in txg by itself. Overlay, named volumes, and timer files do.

| Writer | Path | Cadence | Action |
|--------|------|---------|--------|
| Docker overlay / named volumes | `HDDs/ix-apps/docker` (`/mnt/.ix-apps`) | Continuous while any App or compose stack runs | Move **Apps pool** to `ssd` when free space > **full** `ix-apps` (Immich stays inside that tree). Do not Unset. Do not `data-root`. |
| ALFa Postgres/Redis if still a named volume | same Docker root | WAL / AOF while brain is up | Confirm `.env` binds `ALFA_POSTGRES_DATA_PATH` / `ALFA_REDIS_DATA_PATH` to `/mnt/ssd/alfa-ai/...` |
| `pg-backup.sh` daemon | default `/mnt/HDDs/Alfa-AI/backups/postgres` | `touch` liveness on **container tmpfs** every **30 s** (`LIVENESS_FILE`; `last-success` / `dump-sizes` stay on HDD bind) | Done in compose (`tmpfs: /run/alfa-pg-backup`). Nightly dump files stay on HDD. |
| `write-grev*-pool-env.sh` / `write-grev35-env.sh` | `SLOT_CACHE_DIR` default `/mnt/ssd/Alfa-AI/llama-cpp/slot-cache-111` (nvme then ssd; HDD fallback) | coordinator KV cache writes while pool runs | Done in repo (`default-slot-cache-dir-111.sh`) |
| brain API audit logs | HDD bind if set that way | every admin action | Bind log dir to SSD if it ticks while idle |

`The_Biz` is **not** in any `.yml` / `.sh` / `.ps1`. Parking it is Disks UI
only (Phase A). Jellyfin/Immich media are **not** in this table.

### Low-cadence -- leave on HDD (not the culprit)

| What | Why it is fine |
|------|----------------|
| Immich photos/videos (ixVolume or Host Path) | User browse / mobile backup, not a 30 s loop |
| Jellyfin library and media | Playback is bursty; not idle chatter |
| Hub seed (`HDDs/Alfa-AI` models, wheels, tarballs) | Write once, read on seed |
| Nightly Postgres dump **files** (not the 30 s `touch`) | Once a day is planned spin-up |
| `git pull` / Dockge edits | Operator-initiated |
| Registry / Verdaccio / aria2 when idle | No traffic, no I/O |
| NFS/SMB listing of the hub | Occasional; workers should hit local cache first |

There is **no** `/mnt/nvme` data pool on this host. Boot NVMe is OS only.
Use **`ssd`**, not a hand-made Docker data-root on NVMe
([hub_111_NVME_POOL.md](hub_111_NVME_POOL.md) §3 is **not** the Apps path).

---

## Why Apps cannot move "Docker only"

hub creates **one** hidden `ix-apps` dataset on the chosen Apps pool,
mounted at `/mnt/.ix-apps`. It is internally managed; modifying it can break
apps ([App Storage](https://apps.hub.com/getting-started/app-storage/)).
ixVolumes live **inside** that dataset. Host Path datasets do not.

iX recommends SSD for the Apps pool
([Initial Setup](https://apps.hub.com/getting-started/initial-setup/))
and Host Path (not ixVolume) for permanent app data
([App Storage](https://apps.hub.com/getting-started/app-storage/)).

**Version split (do not mix):**

| hub | Official pool-move UI |
|---------|------------------------|
| **25.10+** | Choose Pool can show **Migrate existing applications**. That copies app images + ixVolumes. Host paths stay put. ([25.10 Apps](https://www.hub.com/docs/scale/25.10/scaleuireference/apps/)) |
| **25.04** | Configuration has **Choose Pool** and **Unset Pool** only. Unset **turns off** the apps service. The 25.04 UI reference does **not** document a migrate copy. ([25.04 Apps](https://www.hub.com/docs/scale/25.04/scaleuireference/apps/)) |

Phase 0 must print the live version (`midclt call system.version` or the UI
footer). If the host is 25.04, do **not** assume a migrate checkbox exists.
Official docs are **silent** on a supported in-place ix-apps copy on 25.04.

**Capacity:** official migrate copies the **whole** `ix-apps` tree, including
Immich/Jellyfin ixVolumes. Last measure: ~633 G used vs `ssd` ~444 G total --
does not fit, and would put photo/video libraries on SSD (out of scope).
There is **no** official "Docker overlay only" move. With Immich left as-is,
**do not Choose Pool migrate.** Cut high-cadence ALFa I/O with host binds
instead (Phase B).

## Repo-verified HDD wake sources (compose/scripts)

Live `.env` is not in git. Defaults:

| Writer | Path | Cadence |
|--------|------|---------|
| `pg-backup.sh` daemon | `ALFA_AI_BACKUP_HOST_DIR` default `/mnt/HDDs/Alfa-AI/backups/postgres` | `touch` `LIVENESS_FILE` on container tmpfs every **30 s** (HDD bind: dumps + `last-success` only) |
| `write-grev*-pool-env.sh` / `write-grev35-env.sh` | `SLOT_CACHE_DIR` default fast tier under `/mnt/ssd/Alfa-AI/llama-cpp/slot-cache-111` | coordinator KV cache writes while pool runs |
| `stackshub.yml` / `deploy.sh` | `repo_root` HDD; `stacks_dir` `/mnt/HDDs/apps/Dockge` | operator git/compose |
| registry / Verdaccio / aria2 | HDD binds | only when those services have traffic |
| brain API | audit logs + optional models bind | when those stacks run |

Postgres/Redis **can** bind SSD via `ALFA_POSTGRES_DATA_PATH` /
`ALFA_REDIS_DATA_PATH` in compose (`deploy/env.example` documents `hub`
paths). Default is a Docker **named volume** (lands in `ix-apps` on HDD).

### Repo path conflicts (inventory of deploy/scripts)

These are in compose/scripts, not docs. They matter before any SSD cutover:

| Conflict | What the files actually do |
|----------|----------------------------|
| Tarball dirs | `build-llamacpp-rpc-cuda128-on-hub.sh` / promote write **`/mnt/HDDs/Alfa-AI/docker-images`**. `deploy.sh` load prefers **`docker/images`**, then falls back to `docker-images`. `seed-base-images-hub.sh` uses **`docker/base-images`**. |
| SSD dataset case | GGUF/RPC hot copy: `/mnt/ssd/Alfa-AI/…`. Stack notes + `preflight-migrate-inventory.sh`: `/mnt/ssd/alfa-ai/postgres`. ZFS is case-sensitive. |
| 35B GGUF | `write-grev35-env.sh` defaults `MODELS_DIR` to HDD only. 27/72/80 writers prefer nvme then ssd then HDD. |
| Brain models bind | `docker-compose.yml` default `ALFA_AI_MODELS_HOST_DIR=/mnt/cluster/models` (NFS **client** path). On `hub` the hub is `/mnt/HDDs/Alfa-AI/models` unless `.env` overrides. |
| Verdaccio | `deploy/npm-proxy/docker-compose.verdaccio.yml` binds HDD; **not** in `stackshub.yml`; no `VERDACCIO_STORAGE` in `env.example`. |
| NFS | `scripts/setup_hub_hub.sh` can append `/etc/exports`. SCALE NFS is **Shares > Unix (NFS) Shares** ([Adding NFS Shares 25.04](https://www.hub.com/docs/scale/25.04/scaletutorials/shares/addingnfsshares/)). `mount_nfs_models.sh` defaults server **`storage`**; `verify_hub_hub.sh` defaults **`hub`**. |
| Docker `data-root` | **Never set** in-repo. `configure-docker-mirror.sh` only merges registry-mirrors. Apps graph stays wherever hub put `ix-apps`. |

---

## Intended sequence (official UI + ALFa binds)

Do **not** Choose Pool migrate while Immich/Jellyfin ixVolumes live in
`ix-apps` (capacity + would copy media onto SSD). Kill the **timer and DB**
writers first.

### Phase 0 -- inventory (read-only on `hub`)

As `operator` / root shell:

```bash
midclt call system.version
zpool list
zfs list -o name,used,avail,mountpoint HDDs/ix-apps ssd The_Biz HDDs
docker info --format '{{.DockerRootDir}} {{.Driver}}'
zfs list -o name | grep '/\.system'
```

Expect Docker root `/mnt/.ix-apps/docker` and system dataset under `ssd/.system`.
Record **`HDDs/ix-apps` used** vs **`ssd` avail**.

On **Storage -> Disks**, note **HDD Standby** and **APM** for every disk in
`HDDs` and `The_Biz` (not SSDs, not boot NVMe).

### Phase A -- park `The_Biz` (no Apps move)

`The_Biz` is already the archive pool. It should spindown once nothing
touches it for the Standby timer.

1. **Storage -> Disks** -> select the `The_Biz` members -> **Edit Disk(s)**.
2. **HDD Standby:** 10 minutes (already used on this host; do not jump to
   330 as a substitute -- [Disks screen](https://www.hub.com/docs/scale/25.04/scaleuireference/storage/disksscreen/)).
3. **Advanced Power Management:** **Level 1 -- Minimum power usage with
   Standby (spindown)** if the drive accepts APM. Leave **Disabled** only if
   a previous change proved the firmware ignores APM.
4. Confirm **Enable S.M.A.R.T.** stays on (25.04 Disks UI). hub 25.04
   SMART **Power Mode** is Never / Sleep / Standby / Idle
   ([SMART service](https://www.hub.com/docs/scale/25.04/scaletutorials/systemsettings/services/smartservicesscale/)).
   Debian `smartd -n standby` skips checks when the disk is **already** in
   STANDBY ([smartd.conf(5)](https://manpages.debian.org/bookworm/smartmontools/smartd.conf.5.en.html)).
   Live `smartd.conf` on `hub` is **not** in this repo -- verify on the host.
   If the box is later **25.10**, the smartd UI is gone and middleware polls
   SMART **every 90 minutes**
   ([version notes](https://www.hub.com/docs/scale/25.10/gettingstarted/versionnotes/)).
   Official docs are **silent** on whether that poll wakes a standby HDD.
5. Dataset hygiene on Biz (and HDD archive datasets you rarely write):
   **Datasets -> Edit -> Advanced -> Enable Atime = Off**
   ([Datasets screens](https://www.hub.com/docs/scale/datasets/datasetsscreens/);
   OpenZFS [atime](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html)).
6. Check **Data Protection** for scrubs / SMART tests / replication whose
   schedule is tighter than the Standby timer. A weekly scrub is fine; a
   5-minute job is not.
7. Confirm no NFS/SMB client is listing Biz continuously (`storage` The_Biz
   NFS alias has been down; leftover fstab on other hosts should stay
   commented -- [NODE_INVENTORY.md](NODE_INVENTORY.md)).

If `zpool iostat The_Biz 5 12` stays ~0 for longer than the Standby minutes
and `smartctl -n standby -i /dev/sdX` still shows the disk **active**,
**official hub docs are silent** on a further SCALE fix (enterprise
drives often ignore APM). Stop there -- do not apply unofficial patches.
Ask whether to live with spinning Biz disks or take it to iX/vendor firmware.

### Phase B -- stop ALFa high-cadence HDD I/O (Immich/Jellyfin untouched)

1. Confirm live `.env` on `hub` binds Postgres and Redis to
   `/mnt/ssd/alfa-ai/...` (not a named volume in `ix-apps`).
2. `pg-backup.sh` liveness on container tmpfs (`LIVENESS_FILE`); `last-success`
   and dump files stay under `/mnt/HDDs/Alfa-AI/backups/postgres`.
3. Default `SLOT_CACHE_DIR` via `default-slot-cache-dir-111.sh` (all
   `write-grev*-pool-env.sh` and `write-grev35-env.sh` on `hub`; operator
   `SLOT_CACHE_DIR` still overrides). Target:
   `/mnt/ssd/Alfa-AI/llama-cpp/slot-cache-111` (or nvme if present).
4. If audit logs tick on an HDD bind while idle, bind that dir to SSD.

No Immich/Jellyfin reinstall. No Host Path conversion. No Apps Unset.

**Rollout facts (verified in code, not assumed):**

| Change | What applies it |
|--------|-----------------|
| `SLOT_CACHE_DIR` -> SSD | A normal orchestrator **stop then start** is enough. `start-pool*` runs `deploy-grev*-coordinator.sh`, which re-runs the `write-grev*` env writer and **regenerates** `deploy/llamacpp-rpc/.env.rpc`. No manual script run needed. |
| Backup heartbeat -> tmpfs | **Not** covered by the orchestrator. The sidecar is a separate compose project and `stop.sh --app-only` leaves it running. Recreate `alfa-ai-postgres-backup` via `deploy/cluster-members/hub/deploy.sh` (or its own compose file). Until then the old **30 s** HDD touch continues. |

A `git pull` alone rewrites neither `.env.rpc` nor a running container.

### Phase C -- Apps pool migrate (deferred)

**Skipped** while Immich/Jellyfin stay inside `ix-apps`. Official migrate
copies the whole tree onto `ssd` ([Initial Setup](https://apps.hub.com/getting-started/initial-setup/))
-- that is the opposite of "media stays on HDD", and it does not fit today.

Revisit only if you add enough SSD **and** accept media landing on `ssd`, or
later choose a Host Path shrink. Until then, overlay I/O for running
containers stays on `HDDs/ix-apps/docker`. Phase B still removes the
**30 s** and slot-cache chatter.

**If 25.04:** the [25.04 Apps UI](https://www.hub.com/docs/scale/25.04/scaleuireference/apps/)
documents Choose Pool and Unset Pool only. **Unset turns the apps service
off.** Do **not** Unset as an experiment.

### Phase D -- HDD Standby (Biz now; HDDs after overlay is gone)

**`The_Biz`:** same Disks UI as Phase A (Standby 10 min, APM Level 1 if
accepted). That pool is already ~0 ZFS I/O.

**`HDDs`:** overlay stays on this pool until a future Apps migrate. After
Phase B, idle chatter should be overlay/txg only -- not a 30 s `touch`.
Do not expect full spindown of `HDDs` while Apps run.

Expect **planned** spin-ups on `HDDs`:

| Event | Why |
|-------|-----|
| Hub seed / `docker save` to `/mnt/HDDs/Alfa-AI/...` | Canonical archive write |
| Worker NFS/SMB cold miss | Local-first failed; reading the hub |
| `git pull` / Dockge on HDD clone | Operator-initiated |
| Immich/Jellyfin use | Photo backup / playback (allowed) |
| ZFS scrub / SMART long test | Data Protection schedule |
| Local replication SSD -> HDD | Backup of runtime datasets ([local replication](https://www.hub.com/docs/scale/25.04/scaletutorials/dataprotection/replication/localreplicationscale/)) |

A nightly or weekly **local replication** of `ssd/alfa-ai` (and optionally
`ssd/ix-apps`) onto `HDDs` or `The_Biz` is the right "archive" of runtime
state. Transport **On this System** -- no SSH. Schedule it **less often**
than HDD Standby so disks can sleep the rest of the day. First run can
**delete existing snapshots on the destination** if none match -- back those
up first
([local replication](https://www.hub.com/docs/scale/25.04/scaletutorials/dataprotection/replication/localreplicationscale/)).

### Phase E -- optional later (live git clone on SSD)

The canonical hub clone can stay on HDD. A **hot** clone on
`/mnt/ssd/repo/alfa-ai` would stop routine operator git I/O from waking
`HDDs`. That is a path/script change across `operator-cluster-111.sh` and
Dockge stacks -- **out of scope until Phases A--D are done**. Do not symlink
the HDD tree into Docker as a workaround.

---

## Verify spindown

After an idle period longer than HDD Standby:

```bash
zpool iostat HDDs 5 6
zpool iostat The_Biz 5 6
```

Near-zero ops/s is necessary but not sufficient (disks can stay spun with no
ZFS I/O). Per-disk:

```bash
sudo smartctl -n standby -i /dev/sdX
```

If the device is in standby, smartctl exits without spinning it up
([smartd.conf(5) `-n`](https://manpages.debian.org/bookworm/smartmontools/smartd.conf.5.en.html)).

Temperature alerts are **disabled for standby disks**
([Disks screen](https://www.hub.com/docs/scale/25.04/scaleuireference/storage/disksscreen/)).

If anything still **dirties** an HDD dataset, OpenZFS may flush at least
every `zfs_txg_timeout` seconds (default **5**)
([zfs.4](https://openzfs.github.io/openzfs-docs/man/v2.4/4/zfs.4.html)).
`atime=off` only stops **atime** writes on read
([zfsprops](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html));
it does not park disks by itself. `hdparm -S` needs **no disk activity**
([hdparm(8)](https://man7.org/linux/man-pages/man8/hdparm.8.html)).

---

## Official SILENT (do not invent)

- 25.04 in-place copy of `ix-apps` to another pool
- Immich ixVolume to Host Path without reinstall (out of scope; not required)
- Whether HDD Standby / APM parks enterprise NAS drives
- Whether 25.10's 90-minute SMART poll wakes standby disks
- Whether an imported idle ZFS pool still writes enough to reset Standby
- Docker `data-root` while hub Apps owns dockerd

---

## Forbidden

- Hand-edit `/etc/docker/daemon.json` `data-root` (hub owns
  `/mnt/.ix-apps/docker` -- [App Storage](https://apps.hub.com/getting-started/app-storage/))
- `Unset Pool` to "force" a move
- Migrating `ix-apps` onto `ssd` when free space is smaller than the dataset
- Piecemeal inference shard/coordinator restart to "save disk watts"
- Unofficial SCALE spindown overlay scripts
- Putting ALFa Postgres/Redis on `HDDs` / `The_Biz` (runtime DBs)

---

## Related

- [CLUSTER_IDLE_POWER.md](CLUSTER_IDLE_POWER.md) -- idle watts; points here for disks
- [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) -- hub seed vs hot copies
- [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) -- HDD hub tree + NFS/SMB
- [HOST_STORAGE_AND_NETWORK_STANDARDS.md](HOST_STORAGE_AND_NETWORK_STANDARDS.md) -- S1 DB / S2 system dataset
- [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) -- brain/Dockge on `hub`
- [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md) -- optional NVMe data pool (not present)
