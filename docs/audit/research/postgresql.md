# PostgreSQL

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://www.postgresql.org/docs/
- **Current (latest stable) docs:** https://www.postgresql.org/docs/current/
- **Versioning policy:** https://www.postgresql.org/support/versioning/
- **Release notes:** https://www.postgresql.org/docs/release/
- **Source:** https://git.postgresql.org/gitweb/?p=postgresql.git
- **Security:** https://www.postgresql.org/support/security/
- **Upgrading guide:** https://www.postgresql.org/docs/current/upgrading.html
- **`pg_hba.conf`:** https://www.postgresql.org/docs/current/auth-pg-hba-conf.html
- **Connection settings:** https://www.postgresql.org/docs/current/runtime-config-connection.html

## Current stable / supported version (as of 2026-05-13)

PostgreSQL versioning policy: 5-year support window per major version, minor releases at least every 3 months. Source: https://www.postgresql.org/support/versioning/.

| Major | Latest minor | Released | First release | EOL |
|---|---|---|---|---|
| **18** | `18.3` | 2026-02-26 | 2025-09-25 | 2030-11-14 |
| **17** | `17.9` | 2026-02-26 | 2024-09-26 | 2029-11-08 |
| **16** | `16.13` | 2026-02-26 | 2023-09-14 | 2028-11-09 |
| **15** | `15.17` | 2026-02-26 | 2022-10-13 | 2027-11-11 |
| **14** | `14.22` | 2026-02-26 | 2021-09-30 | **2026-11-12** (last 6 months of support) |

- **Newest major:** `18.3` (2026-02-26).
- **Recommended for new deploys:** `17.x` (most recent year-old major) or `18.x` (latest, if early-adopter risk acceptable).
- **At-risk:** PostgreSQL `14.x` reaches EOL **2026-11-12** — only ~6 months remain. Plan major-version upgrades before that.
- **EOL'd in 2025:** PostgreSQL 13 (EOL 2025-11-13). Source: https://www.postgresql.org/support/versioning/.

Source for all rows: https://www.postgresql.org/support/versioning/ ("Releases" table, last updated for the 2026-02-26 minor releases).

## Key official best practices

- **Run minor releases promptly.** Minor releases contain only bug + security fixes — upgrading is just install + restart, no dump/restore required. Source: https://www.postgresql.org/support/versioning/ ("Upgrading").
- **Major-version upgrades** require `pg_upgrade` or dump/restore. Source: https://www.postgresql.org/docs/current/pgupgrade.html.
- **`listen_addresses`:** default is `localhost`. To accept LAN connections, set explicitly to interface(s) — never trust default. Source: https://www.postgresql.org/docs/current/runtime-config-connection.html#GUC-LISTEN-ADDRESSES.
- **`pg_hba.conf` auth method:** **prefer `scram-sha-256`** for password authentication. `md5` is deprecated; `password` (cleartext) and `trust` are insecure. The default `password_encryption = scram-sha-256` (since PG 14) is correct — keep it. Source: https://www.postgresql.org/docs/current/auth-pg-hba-conf.html and https://www.postgresql.org/docs/current/auth-password.html.
- **Connection limits:** `max_connections` defaults to 100. With LiteLLM workers + bots + APIs, plan total demand and use **PgBouncer** in transaction-pooling mode for high-fanout services. Source: https://www.postgresql.org/docs/current/runtime-config-connection.html.
- **TLS:** set `ssl = on`, `ssl_cert_file`, `ssl_key_file`, and require TLS via `hostssl ... scram-sha-256` lines in `pg_hba.conf` for any non-loopback client. Source: https://www.postgresql.org/docs/current/ssl-tcp.html.
- **WAL / backup:** for production, run `pg_basebackup` + WAL archiving (`archive_mode = on`, `archive_command = ...`) to a separate volume. PITR (point-in-time recovery) is the canonical recovery story. Source: https://www.postgresql.org/docs/current/continuous-archiving.html.
- **Containers:** the official Docker image is at https://hub.docker.com/_/postgres. Pin `postgres:17-alpine` (or 18) — never `:latest`. Always mount `/var/lib/postgresql/data` as a named volume or bind-mount. Source: https://hub.docker.com/_/postgres.
- **Tuning:** the canonical starting point is `shared_buffers = 25% RAM`, `effective_cache_size = 50–75% RAM`, `work_mem = ~RAM/max_connections/4`. Source: https://www.postgresql.org/docs/current/runtime-config-resource.html. (Tools like `pgtune` give first-pass values.)
- **Roles & least privilege:** create per-app roles (`alfa_ai`, `litellm_proxy`, `bots`) with explicit GRANTs — don't let app code use `postgres` superuser. Source: https://www.postgresql.org/docs/current/sql-createrole.html.

## Canonical configuration examples

**`pg_hba.conf` for a typical LAN deployment** (verbatim shape from https://www.postgresql.org/docs/current/auth-pg-hba-conf.html):

```text
# TYPE   DATABASE   USER          ADDRESS              METHOD
local    all        postgres                           peer
host     all        all           127.0.0.1/32         scram-sha-256
host     all        all           ::1/128              scram-sha-256
hostssl  alfa_ai    alfa_ai_app   orchestrator/24       scram-sha-256
host     replication replicator   orchestrator/24       scram-sha-256
```

**`postgresql.conf` essentials** (https://www.postgresql.org/docs/current/runtime-config-connection.html):

```conf
listen_addresses = '*'                # bind all; let pg_hba.conf gate clients
port = 5432
max_connections = 200

password_encryption = scram-sha-256
ssl = on
ssl_cert_file = '/etc/ssl/certs/postgres.crt'
ssl_key_file  = '/etc/ssl/private/postgres.key'

shared_buffers = 4GB
effective_cache_size = 12GB
work_mem = 32MB
maintenance_work_mem = 512MB
wal_level = replica
archive_mode = on
archive_command = 'cp %p /var/lib/pgsql/archive/%f'
```

## Common pitfalls / gotchas

- **`md5` auth is deprecated** but still common in copy-pasted configs; replace with `scram-sha-256`. Source: https://www.postgresql.org/docs/current/auth-password.html.
- **`trust` in `pg_hba.conf`** = no auth at all. Never on a host line, even on a private network. Source: https://www.postgresql.org/docs/current/auth-trust.html.
- **`listen_addresses = '*'` without firewall** exposes the DB. Bind explicitly to LAN interface or rely on Docker's internal network only. Source: https://www.postgresql.org/docs/current/runtime-config-connection.html.
- **Default `max_connections = 100`** is silently exhausted by LiteLLM (10/worker × 4 workers × 2 instances = 80) plus other apps. Bump it explicitly or use PgBouncer. Source: https://www.postgresql.org/docs/current/runtime-config-connection.html.
- **Forgetting WAL archiving** loses point-in-time recovery — without it, a backup is only as recent as your last `pg_basebackup`. Source: https://www.postgresql.org/docs/current/continuous-archiving.html.
- **Major version upgrade requires `pg_upgrade` or dump+restore.** Restoring data via `docker volume mount` from PG 14 → PG 17 will silently refuse on first start. Source: https://www.postgresql.org/docs/current/upgrading.html.
- **Major upgrades of `postgres:<N>-alpine` Docker images** silently fail because the data directory layout differs across majors. Always run `pg_upgrade` (or use the `tianon/postgres-upgrade` image). Source: same.
- **`14.x` EOL on 2026-11-12.** Anyone still on 14.x has 6 months. Source: https://www.postgresql.org/support/versioning/.

## Authoritative URLs to cite in our docs

- https://www.postgresql.org/docs/
- https://www.postgresql.org/docs/current/
- https://www.postgresql.org/support/versioning/
- https://www.postgresql.org/support/security/
- https://www.postgresql.org/docs/current/auth-pg-hba-conf.html
- https://www.postgresql.org/docs/current/auth-password.html
- https://www.postgresql.org/docs/current/runtime-config-connection.html
- https://www.postgresql.org/docs/current/runtime-config-resource.html
- https://www.postgresql.org/docs/current/continuous-archiving.html
- https://www.postgresql.org/docs/current/upgrading.html
- https://www.postgresql.org/docs/current/pgupgrade.html
- https://www.postgresql.org/docs/current/ssl-tcp.html
- https://hub.docker.com/_/postgres

## AUDIT CHECKLIST for the Audit Agent

1. **Major version pin:** confirm Postgres on `apps` (per `NODE_INVENTORY.md`) is on a supported major (14.x, 15.x, 16.x, 17.x, or 18.x). Path: docker-compose for `apps` apps host (under `apps-105/` or per-app compose). Flag any image tag like `postgres:13-*`.
2. **EOL countdown:** if running 14.x, flag with severity = warning that EOL is **2026-11-12**. Cross-reference the table above.
3. **Auth method in `pg_hba.conf`:** confirm all entries use `scram-sha-256`, NOT `md5`/`password`/`trust`. Path: any `init.sql` or mounted `pg_hba.conf` in the Postgres compose.
4. **TLS:** confirm `ssl = on` for any cross-host Postgres traffic (LiteLLM on `hub` connecting to Postgres on `apps`). If LiteLLM-to-Postgres goes over the LAN unencrypted, flag.
5. **`listen_addresses`:** the Postgres on `apps` is reached from `hub` (LiteLLM) and from `apps` apps. Confirm `listen_addresses` is set to specific LAN interface(s) and that the Docker port mapping uses `127.0.0.1:5432:5432` style binding per workspace `port-assignment-rules.mdc` — OR exposed only over `tunnel_network` Docker network.
6. **`max_connections` budget:** total expected concurrent connections from LiteLLM (workers × pool × instances) + bots + APIs must be less than `max_connections`. With 2 LiteLLM instances × 4 workers × 10 pool = 80 connections just for LiteLLM. Verify the value in `postgresql.conf` or compose env.
7. **PgBouncer presence:** if total demand > 100, confirm PgBouncer is in front of Postgres in transaction-pooling mode. Path: `apps-105/`.
8. **WAL archiving:** confirm `archive_mode = on` and `archive_command` writes to a path on the persistent SSD pool (`apps` local SSD or NFS to `hub`). Without it, only `pg_basebackup` snapshots exist.
9. **Backup cadence:** confirm a `pg_basebackup` (or `pg_dumpall`) cron/service runs at least daily, and that backups are written to `hub` shared storage (not just local to `apps`). Cross-check `CLUSTER_SHARED_STORAGE.md`.
10. **Volume persistence:** confirm `/var/lib/postgresql/data` is a named volume or bind-mount, NOT a container-ephemeral path.
11. **Per-app roles:** confirm separate roles for `alfa_ai`, `litellm` (or `litellm_proxy`), and per-bot DBs — none should share a superuser. List in `apps-105/README.md` or equivalent.
12. **LiteLLM salt key consistency:** see `litellm.md` audit item — Postgres `litellm_db` rows are encrypted with `LITELLM_SALT_KEY`, which must be identical across both LiteLLM instances reading the DB.
13. **Image tag:** confirm `postgres:17-alpine` (or 18) — never `:latest` — in compose.
