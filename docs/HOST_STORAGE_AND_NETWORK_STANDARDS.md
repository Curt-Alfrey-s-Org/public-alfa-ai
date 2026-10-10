# Host storage placement & network hygiene standards

**Origin:** 2026-06-19 idle-I/O investigation on `hub` (brain/hub). The box
was doing continuous read/writes to its HDD array while idle, causing heat and
slowdowns. Root causes were host-hygiene issues that apply fleet-wide, so they
are captured here as standards. See also
[audit/audit-findings.md](audit/audit-findings.md) (INFRA-/STORAGE-/NET- IDs).

## Applicability

| Standard | `hub` hub | `apps` Linux apps | `orchestrator`/`gaming-a`/`gaming-b`/`gaming-c`/`secondary` Win/WSL |
|----------|:---:|:---:|:---:|
| S1 — App DB storage placement (`ALFA_AI_*_DATA_PATH`) | done | check | check (any host running the DB stack) |
| S2 — hub system dataset on a fast pool | done | n/a | n/a |
| S3 — Linux bridge single-uplink (no L2 loop) | done | check | n/a (WSL/Hyper-V networking) |

`hub` is currently the only hub host. S2 applies only to hub hosts; S3
applies to any host using a Linux bridge (`brN`) with physical NIC members.

---

## S1 — App database storage placement

**Standard:** Postgres/Redis (and other write-hot DB) data must sit on the
host's **fast pool** (SSD/NVMe), never on a slow/HDD-backed Docker named volume.
The compose is **host-agnostic**; each host opts in via its own (gitignored)
`deploy/.env`.

### Contract (implemented in dedicated DB stacks)

Postgres and Redis are provided by the dedicated protected stacks
(`deploy/docker-compose.postgres.yml` and `deploy/docker-compose.redis.yml`).
The volume pattern below is used by those stacks (not by the brain monolithic compose).

```yaml
services:
  postgres:   # or alfa-postgres depending on container_name in the stack
    volumes:
      - ${ALFA_POSTGRES_DATA_PATH:-alfa-postgres-data}:/var/lib/postgresql/data
  redis:
    volumes:
      - ${ALFA_REDIS_DATA_PATH:-alfa-redis-data}:/data
```

Compose treats a source starting with `/` as a **bind mount** and anything else
as a **named volume**. Therefore:

- **Unset / blank** (default) -> Docker named volume (original behavior). Hosts
  that don't set the var are unaffected — safe default for the whole fleet.
- **Absolute path on a fast pool** -> bind mount to that path.

Documented via the stack envs and `deploy/env.example` / `env.apps.example`. Set per host:

```sh
# hub (hub — ssd mirror pool) — for the dedicated postgres/redis stacks
ALFA_POSTGRES_DATA_PATH=/mnt/ssd/alfa-ai/postgres
ALFA_REDIS_DATA_PATH=/mnt/ssd/alfa-ai/redis
```

The brain compose no longer owns DB volumes. Dedicated stacks own the data. Never `-v` the stacks.

### Migrating an existing host (stop -> copy -> repoint -> verify)

1. Create fast-pool datasets (hub: `midclt call pool.dataset.create`; plain
   Linux: a directory on the SSD pool).
2. **Back up first:** `pg_dump` the DB + (hub) a ZFS snapshot.
3. Stop the stack: `docker compose stop`.
4. Copy preserving ownership: `cp -a <named-vol>/_data/. <fast-path>/` then
   `chown` to the container UID (Postgres alpine = `70:70` mode `700`;
   Redis alpine = `999:1000`).
5. Set the `ALFA_AI_*_DATA_PATH` vars in `deploy/.env`.
6. `docker compose up -d`; verify `docker inspect … {{.Mounts}}` points at the
   fast pool and the DB is `healthy`.
7. Reclaim the old volume once satisfied: `docker volume rm <name>`.

> The 2026-06-19 `hub` migration used `migrate_alfa_db.sh` (snapshot + `pg_dump`
> + ownership-preserving copy + verify) followed by `encode_alfa_storage.sh`
> (parameterize compose + set `.env`). Both are reversible.

### Follow-ups (other stacks still on HDD named volumes)

These were found using DB named volumes on `hub` and should get the same
treatment (parameterize + relocate to a fast pool):

- `alfa-ai-cluster/repo/alfa-ai/deploy/docker-compose.yml`
- `monitoring/docker-compose.yml`
- `market-pie5-bot`, `contracts-bot`, `rv-auto-finder`, `atems`, `credit-check-bot`

---

## S2 — hub system dataset on a fast pool

**Standard:** the hub **System Dataset** (`.system` — holds `netdata`,
`samba4`, audit metadata, cores) must live on an **SSD/fast pool**, not the
data/HDD array. On the HDD array it generates continuous background writes
(netdata RRD + samba + audit) that keep the disks spinning and warm even when
the host is idle.

**Set it (WebUI):** System Settings -> Advanced -> Storage -> **System Dataset
Pool** -> choose the SSD pool -> Save (migrates live).

**Verify:**

```sh
zfs list -o name | grep '/\.system'   # expect ssd/.system/... not HDDs/.system/...
zpool iostat <hdd-pool> 2 3           # idle intervals should show 0 writes
```

`hub` was moved `HDDs` -> `ssd` on 2026-06-19; HDD array went from ~never-idle
to ~59%+ idle at rest.

---

## S3 — Linux bridge: single uplink, no L2 loop

**Standard:** a Linux bridge (`brN`) must have **exactly one** physical uplink
(or a single **LAGG/bond**). **Never** enslave multiple physical NICs that land
on the same switch/L2 — it creates a loop. STP will block the redundant port,
but the kernel still logs, every ~30 s, 24/7:

```
brN: received packet on <nicA> with own address as source address (addr:<nicB-mac>)
```

Every such line is written by journald + syslog-ng -> constant disk writes (and
on hub, audit-DB churn). Docker/incus create their own bridges; the host
bridge only needs one uplink for management.

### Detect (any bridge host)

```sh
# loop log rate (should be 0)
journalctl -k -b | grep -c "own address as source"
# bridge members (expect one physical uplink)
ls /sys/class/net/<bridge>/brif/
# which member learned the gateway MAC = the real uplink to KEEP
GW=$(ip route show default | awk '{print $3; exit}')
GWMAC=$(ip neigh show "$GW" | awk '{print $5; exit}')
bridge fdb show | grep -i "$GWMAC"
```

### Fix (hub WebUI)

Network -> Interfaces -> `<bridge>` -> Bridge Members -> keep only the chosen
uplink (highest-speed, carries the gateway MAC) -> Save -> **Test Changes**
(60 s auto-rollback safety). For multiple links, use a LAGG and bridge that.

**Current (2026-09-04):** hub **`hub` LAN = `br1`** — cabinet cables are one L2 domain; IPv4 **`hub/24` + `storage/32` NFS VIP** on the bridge only ([hub bridge setup](https://www.hub.com/docs/scale/network/interfaces/settingupbridge/), [hub_111_10G_NIC.md](hub_111_10G_NIC.md)). **Stale:** Jun 2026 "np0 only / np1 not cabled"; Jul 2026 triple-NIC split — superseded by `br1`.

---

## Related

- [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md) — `hub` hot storage layout
- [DEPLOYMENT_BASELINE.md](DEPLOYMENT_BASELINE.md) — compose/network baseline
- [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md) — per-host readiness
- [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) — HDD tree + shared planes
- [audit/audit-findings.md](audit/audit-findings.md) — INFRA-/STORAGE-/NET- findings
