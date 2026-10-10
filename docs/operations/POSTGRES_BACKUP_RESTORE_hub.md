# Brain Postgres backup & restore — `hub` (hub)

> ROADMAP "Production readiness plan" **Phase 3** items 1–3 / audit
> **PG-005** (docs/audit/audit-findings.md). Postgres/Redis run as **protected dedicated stacks**
> (`deploy/docker-compose.postgres.yml` and `deploy/docker-compose.redis.yml`, declared in stackshub.yml).
> The brain stack no longer owns the DB containers. The backup sidecar targets the dedicated DB instance.
> All files referenced here are authored on `apps` and reach `hub` via
> `git pull` (git-push-from-105 workflow).

## 1. Design (what runs, where it lands)

| Aspect | Choice | Why / source |
|---|---|---|
| Method | Nightly logical dump: `pg_dump -Fc` (custom format) per database + `pg_dumpall --globals-only` for roles | PG 16 manual [SQL dump](https://www.postgresql.org/docs/16/backup-dump.html), [pg_dump](https://www.postgresql.org/docs/16/app-pgdump.html), [pg_dumpall](https://www.postgresql.org/docs/16/app-pg-dumpall.html). Custom format is compressed and feeds `pg_restore` selectively. |
| PITR / WAL archiving | **Out of scope** — closes audit PG-005 with an explicit operator choice (nightly dump, ≤24 h data-loss window) instead of [continuous archiving](https://www.postgresql.org/docs/16/continuous-archiving.html) | Brain DB is small, low-write; the acceptable-loss contract is one day. Revisit if the DB starts holding irreplaceable per-hour state. |
| Scheduler / owner | Sidecar container `alfa-ai-postgres-backup` (`deploy/docker-compose.postgres-backup.yml`), daemon loop at `ALFA_AI_PG_BACKUP_TIME` (default 03:30 UTC) + catch-up at start when last success > 26 h old | Compose is the single process owner of the brain stack on `hub` (`deployment-process-ownership.mdc`) — no second host-cron starter. Same `postgres:16.13-alpine` image pin as the server, so `pg_dump` matches the server major. |
| Verification | `pg_restore --list` against every fresh dump before it is moved into place | [pg_restore](https://www.postgresql.org/docs/16/app-pgrestore.html) cannot list a corrupt archive — cheap end-to-end readability check. |
| Retention | **7 daily / 4 weekly** + 7 globals; weekly promoted from the daily dump when the newest weekly is > 6 days old | Phase 3 target; self-healing (no dependence on a specific weekday being up). |
| Location | `/mnt/HDDs/Alfa-AI/backups/postgres/{daily,weekly,globals,metrics,state}` (override: `ALFA_AI_BACKUP_HOST_DIR`) | Canonical HDD hub tier — capacity planning and DR assume the HDD pool ([CLUSTER_SHARED_STORAGE.md](../CLUSTER_SHARED_STORAGE.md) §1). Not the NVMe/SSD fast tier (must stay rebuildable). |
| Freshness hook | `metrics/alfa_ai_pg_backup.prom` (node_exporter [textfile-collector](https://github.com/prometheus/node_exporter#textfile-collector) format) + `state/last-success` epoch | §4 below — Phase 4 wiring lands in the `monitoring` repo later. |
| AI dependency | None — the sidecar and the drill script never touch LiteLLM/the brain API | Graceful-degrade contract (`alfa-ai-usage.mdc`). |

Dumps cover **every non-template database** in the instance (the `alfaai` app
DB plus the LiteLLM/Prisma database when LiteLLM provisions one), so an
operator adding a DB later is covered without editing the job.

Files:

- `deploy/postgres/backup/pg-backup.sh` — backup daemon (runs in the sidecar)
- `deploy/docker-compose.postgres-backup.yml` — sidecar compose project
- `deploy/postgres/backup/pg-restore-test.sh` — throwaway-container restore drill
- Deploy hook: `deploy/cluster-members/hub/deploy.sh` §5b; stack entry
  `alfa-postgres-backup` in `stackshub.yml`

## 2. Deploy / operate (on `hub`)

Deployed automatically by the standard flow (`git pull` + `sudo bash
deploy/cluster-members/hub/deploy.sh`). To bring up or refresh just
the sidecar:

**From `hub` (hub — SSH, zsh):**

```bash
setopt interactivecomments
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && sudo docker compose --env-file .env -f docker-compose.postgres-backup.yml up -d
```

Check it is running and healthy:

```bash
setopt interactivecomments
sudo docker ps --filter name=alfa-ai-postgres-backup
```

Run an immediate manual backup (idempotent; rotation cleans up):

```bash
setopt interactivecomments
sudo docker exec alfa-ai-postgres-backup /bin/sh /usr/local/bin/pg-backup.sh once
```

Inspect what exists:

```bash
setopt interactivecomments
sudo ls -lht /mnt/HDDs/Alfa-AI/backups/postgres/daily
```

Logs (each run logs `backup run OK` or a loud `ERROR`):

```bash
setopt interactivecomments
sudo docker logs --tail 50 alfa-ai-postgres-backup
```

A failed run does **not** crash the sidecar — failure is surfaced via
`docker logs`, `alfa_ai_pg_backup_last_run_exit_code`, and the freshness
metric going stale (§4).

## 3. RESTORE runbook

> Conventions: zsh on `hub`, `sudo docker`, **one command per paste block**
> (`hub-111-operator-zsh.mdc` / `hub-111-sudo-docker.mdc`). Replace
> `<FILE>` with a real dump name from `daily/` or `weekly/`
> (format `<db>-YYYYmmdd-HHMMSS.dump`). The restore commands run inside the
> backup sidecar because it already has the backups mounted at `/backups`,
> network reachability to `alfa-postgres`, and `PGPASSWORD` set.

### 3a. Restore one database in place (data loss / bad migration)

Pick the dump:

```bash
setopt interactivecomments
sudo ls -lht /mnt/HDDs/Alfa-AI/backups/postgres/daily
```

Stop the writers (keep postgres itself running):

```bash
setopt interactivecomments
sudo docker stop alfa-ai-api alfa-ai-litellm
```

Restore (atomic: `--single-transaction` rolls everything back on any error;
`--clean --if-exists` drops existing objects first):

```bash
setopt interactivecomments
sudo docker exec alfa-ai-postgres-backup pg_restore -d alfaai --clean --if-exists --single-transaction --exit-on-error /backups/daily/<FILE>
```

For the LiteLLM database, repeat with `-d <litellm-db-name>` and its
`daily/<litellm-db-name>-*.dump` file.

Restart the writers:

```bash
setopt interactivecomments
sudo docker start alfa-ai-api alfa-ai-litellm
```

Health-poll (never one-shot curl while `(health: starting)` —
[WAIT_POLL_OPERATOR.md](../WAIT_POLL_OPERATOR.md)):

```bash
setopt interactivecomments
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/wait-brain-health.sh 60
```

Paste the full terminal output of each step before moving to the next if
anything looks off.

### 3b. Full disaster (Postgres volume lost / fresh host)

Bring up only Postgres + the backup sidecar from the repo checkout:

```bash
setopt interactivecomments
# Dedicated protected stack (not inside brain compose):
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && sudo docker compose --env-file .env -f docker-compose.postgres.yml up -d
```

```bash
setopt interactivecomments
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && sudo docker compose --env-file .env -f docker-compose.postgres-backup.yml up -d
```

Restore cluster globals (roles/grants) first:

```bash
setopt interactivecomments
sudo docker exec alfa-ai-postgres-backup sh -c 'psql -d postgres -f /backups/globals/<GLOBALS-FILE>.sql'
```

Restore each database (`--clean --create` drops the empty bootstrap DB and
recreates it from the dump):

```bash
setopt interactivecomments
sudo docker exec alfa-ai-postgres-backup pg_restore -d postgres --clean --create --if-exists --exit-on-error /backups/daily/<FILE>
```

Repeat the previous block for every database that has dumps in `daily/`
(at minimum `alfaai`; also the LiteLLM DB if present). Skip the
`postgres-*.dump` files — the `postgres` maintenance DB is dumped for
completeness but is normally empty, and `--clean --create` cannot drop the
database you are connected to. Then bring up the full brain stack the
canonical way:

```bash
setopt interactivecomments
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/deploy.sh --skip-pull
```

Verify:

```bash
setopt interactivecomments
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/wait-brain-health.sh 120
```

### 3c. Periodic restore test (quarterly — required)

Restores the newest daily dump into a **throwaway** container (production
Postgres and its volume are never touched), verifies tables exist, and cleans
up. Run quarterly; record the `RESULT: OK` line in `logs/cluster-status/`.

```bash
setopt interactivecomments
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/postgres/backup/pg-restore-test.sh
```

## 4. Backup-freshness check (monitoring hook)

Every run rewrites (atomically) the textfile-collector metrics file on the
host at `ALFA_AI_BACKUP_HOST_DIR/metrics/alfa_ai_pg_backup.prom`:

| Metric | Meaning |
|---|---|
| `alfa_ai_pg_backup_last_success_timestamp_seconds` | Unix time of the last fully verified run — **alert when `time() - this > 100000` (~28 h)** |
| `alfa_ai_pg_backup_last_run_timestamp_seconds` | Last attempted run |
| `alfa_ai_pg_backup_last_run_exit_code` | 0 = success |
| `alfa_ai_pg_backup_last_run_duration_seconds` | Run duration |
| `alfa_ai_pg_backup_dump_bytes{database="…"}` | Newest verified dump size per DB (alert on sudden shrink) |

Phase 4 wiring (later, `monitoring` repo): run/point a node_exporter on
`hub` with `--collector.textfile.directory=/mnt/HDDs/Alfa-AI/backups/postgres/metrics`
([node_exporter textfile collector](https://github.com/prometheus/node_exporter#textfile-collector)).
Until then, a human check works:

```bash
setopt interactivecomments
sudo cat /mnt/HDDs/Alfa-AI/backups/postgres/metrics/alfa_ai_pg_backup.prom
```

Per the graceful-degrade contract, monitoring being down never affects the
backup job itself.

## 5. Redis: persistence posture — **no backup job, by decision**

The dedicated `alfa-redis` (protected redis stack) is configured as a **bounded cache**, not a
durable store, so it is intentionally **excluded** from the backup job:

- **Eviction is enabled:** `--maxmemory ${REDIS_MAXMEMORY:-256mb}
  --maxmemory-policy allkeys-lru` (`deploy/docker-compose.yml`). Redis may
  evict *any* key at any time under memory pressure — by configuration the
  data is already declared loss-tolerant. Backing up an evicting cache would
  be drift, not safety.
- **Everything stored in it is reconstructible or TTL-bounded:**
  - LiteLLM router/cooldown state — rebuilt from `litellm_config.yaml` +
    health checks on restart.
  - Petals worker heartbeats (`src/api/redis_heartbeat.py`) — TTL'd; workers
    re-publish on their next heartbeat.
  - Petals bootstrap multiaddrs (`src/api/redis_petals.py`) — TTL 600 s;
    re-published by the bootstrap worker, with an NFS DR fallback
    (`petals/bootstrap/bootstrap.multiaddr`, see CLUSTER_SHARED_STORAGE.md).
  - Runtime task queue (`src/runtime/queue.py`) — transient in-flight task
    IDs only; durable run state lives in Postgres.
- **Restart persistence is still on:** `--appendonly yes` (AOF) on the named
  volume `alfa-redis-data` (owned by the dedicated redis stack compose; see `docker-compose.redis.yml`),
  so a container restart does not even cold-start the cache.

**Acceptable-loss contract:** total loss of Redis costs at most in-flight
queued task IDs and a few minutes of heartbeat/router warm-up. If a future
feature puts durable state in Redis, that feature must move the state to
Postgres or this decision must be re-made here (and an RDB/AOF copy step
added to the backup sidecar).

## 6. Still operator-owned (not in this repo)

- First deploy on `hub` (`git pull` + `deploy.sh`) and the **first restore
  drill** (§3c) — Phase 3 "restored at least once" gate.
- `apps` apps DB (`deploy/docker-compose.postgres.yml`) backup job — separate
  Phase 3 line item, not covered by this sidecar.
- ZFS snapshot schedule for the `hub` NVMe-pool datasets (Phase 3 item 4 —
  hub UI).
- Optional off-host copy of `/mnt/HDDs/Alfa-AI/backups/` (ZFS replication of
  the hub dataset covers it once snapshots are scheduled).
