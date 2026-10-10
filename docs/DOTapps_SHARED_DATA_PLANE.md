# `apps` shared data plane — Redis & Postgres inventory

**Host:** `apps` (`web-sites`, Ubuntu KVM guest).  
**Purpose:** Operators often run **multiple Docker Compose projects** on this machine (`alfa-ai` apps stacks + per-bot repos). This doc maps **which Redis/Postgres instances belong to which repo** and how they relate to **shared** `alfa-*` services from [`deploy/cluster-members/apps/stacksapps.yml`](../deploy/cluster-members/apps/stacksapps.yml).

**Canonical hardware / Petals role:** [NODE_INVENTORY.md](NODE_INVENTORY.md), [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md).

---

## Redis

| Container name | Compose source | Host bind | Purpose |
|----------------|----------------|-----------|---------|
| **`alfa-redis`** | [`deploy/docker-compose.redis.yml`](../deploy/docker-compose.redis.yml) via `deploy.sh` + **`deploy/.env.apps`** | **`127.0.0.1:6379`** → container `6379` | **Shared brain-adjacent cache:** sessions, task queue, worker heartbeats when `hub` brain is configured to use `apps` Redis. Requires **`REDIS_PASSWORD`** in `.env.apps`. |
| **`rankings-bot-redis`** | [`rankings-bot/production/docker-compose.prod.yml`](../../rankings-bot/production/docker-compose.prod.yml) | **No host publish** — internal port **`6379`** only on Docker networks (`rankings-bot-network`, `tunnel_network`) | **Rankings-bot only:** Celery broker + app `REDIS_URL` (`redis://redis:6379/0` inside compose). **Independent** volume from `alfa-redis`. |

**Do not confuse:** two containers, two volumes, two operational owners. Changing **`alfa-redis`** password affects only consumers whose **`REDIS_URL`** points at **`127.0.0.1:6379`** on `apps`; rankings-bot uses **`rankings-bot-redis`** via Docker DNS **`redis`**.

---

## Postgres

| Container name | Compose source | Host bind | Purpose |
|----------------|----------------|-----------|---------|
| **`alfa-postgres`** | [`deploy/docker-compose.postgres.yml`](../deploy/docker-compose.postgres.yml) via `deploy.sh` + **`deploy/.env.apps`** | **`127.0.0.1:5432`** → container `5432` | **Shared DB** for brain + any bot/service whose **`DATABASE_URL`** targets this instance (`ALFA_POSTGRES_*` in `.env.apps`; default DB/user **`alfaai`** per [`env.apps.example`](../deploy/cluster-members/apps/env.apps.example)). |
| **`rankings-bot-postgres`** | `rankings-bot/production/docker-compose.prod.yml` | **No host publish** — **`5432`** inside container network | **Rankings production DB** (`DATABASE_URL` → `rankings-bot-postgres:5432`). |
| **`rankings-bot-postgres-testcenter`** | same | **No host publish** — **`5432`** inside container network | **Rankings Test Center** isolated Postgres (`TEST_CENTER_DATABASE_URL`). |
| **`market-pie5-bot-postgres`** | [`market-pie5-bot/docker-compose.yml`](../../market-pie5-bot/docker-compose.yml) | **`127.0.0.1:5435:5432`** | **Market bot only** (`DATABASE_URL` in market `.env`). |

**Intent vs reality:** `stacksapps.yml` notes describe **`alfa-postgres`** as the shared brain DB; several bots **still ship embedded Postgres** for standalone deploys. Which DB a bot uses is determined by its **live `.env`** (`DATABASE_URL`), not by this repo layout alone.

---

## Petals GPU on `apps` — tier **3a** (70B) shard + bootstrap

`apps` runs **DHT bootstrap** (CPU/network-bound) and a **last-resort Petals gateway** **and** a **`petals-worker`** process that holds part of **`meta-llama/Llama-3.3-70B-Instruct`** (NF4) for **frontier-chat**. The **6 GB** GPU contributes a **small share** of the **80** transformer blocks (operator docs often cite **~2–3** blocks as a planning shorthand; Petals may auto-fill more depending on VRAM — see worker logs). That slice is **production-intended**: it improves **redundancy** and **load spread**, not optional fluff.

**Cluster decision (May 2026):** **Keep** bootstrap **+** **70B worker** **+** gateway (**Option A**) unless there is an **explicit** decision to move bootstrap to **`secondary`** and/or repurpose the GPU — see [ROADMAP.md](ROADMAP.md) § *Petals 70B (tier 3a) — `apps` GPU shard (committed)*.

### Historical alternatives (require architecture review)

| Option | Petals worker shards on `apps` | Notes |
|--------|----------------------------------|--------|
| **A (committed)** | **Keep** bootstrap + worker + gateway | Matches [`apps-105/env.worker.example`](../deploy/cluster-members/apps/env.worker.example) (`PETALS_IS_BOOTSTRAP=1`). |
| **B** | **Stop** worker blocks; repurpose GPU (e.g. embeddings standby Ollama) | Requires LiteLLM/embed routing changes + freeing GPU from Petals compose. |
| **C** | **Stop** worker blocks; small-model Ollama on `apps` | Same coordination as B; do **not** collide with cluster port/registry conventions. |

### Operator verification snapshot

Example **`docker ps`** excerpt from **`web-sites` (`apps`)** — **2026-05-14**:

```
NAMES                             PORTS                         STATUS
market-pie5-bot-postgres          127.0.0.1:5435->5432/tcp      healthy
petals-worker                     (host network)                Up
alfa-redis                        127.0.0.1:6379->6379/tcp      healthy
alfa-postgres                     127.0.0.1:5432->5432/tcp      healthy
rankings-bot-postgres             5432/tcp (internal)           healthy
rankings-bot-postgres-testcenter  5432/tcp (internal)           healthy
rankings-bot-redis                6379/tcp (internal)           healthy
```

Re-run the **`docker ps … grep`** one-liner below after deploy changes.

---

## Live verification on `apps`

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}' | grep -E 'alfa-postgres|alfa-redis|rankings-bot-postgres|rankings-bot-redis|market-pie5-bot-postgres|petals-worker|NAME'
```

Postgres probe (shared):

```bash
docker exec -it alfa-postgres psql -U alfaai -d alfaai -c 'SELECT 1;'
```

Redis probe (**use password from `deploy/.env.apps`**):

```bash
docker exec -it alfa-redis redis-cli -a "$REDIS_PASSWORD" ping
```

---

## hub (brain) dedicated Postgres/Redis stacks

On `hub`, Postgres and Redis are also provided by the **same dedicated split compose files** (`deploy/docker-compose.postgres.yml`, `deploy/docker-compose.redis.yml`) declared as protected stacks in `stackshub.yml`.

These stacks are **critical protected infrastructure**:
- Never stopped by cluster stop (`operator-cluster-111.sh stop` or the orchestrator orchestrator).
- Volumes are never removed by cluster operations (`down -v` is forbidden against these projects).
- The brain compose on hub no longer defines `alfa-ai-postgres` / `alfa-ai-redis` services.

Configure data location and credentials via the stack's env (or the host `.env` used by the stack). Brain services connect via the shared Docker network (DNS names `alfa-postgres` / `alfa-redis`) or explicit URLs.

See:
- `stackshub.yml` for the stack declarations.
- `DOCKGE_111_OPERATOR.md` for operator notes.
- `HOST_STORAGE_AND_NETWORK_STANDARDS.md` for SSD/NVMe placement.

## Protection in cluster lifecycle and data safety (priority sites)

Postgres and Redis (on both hosts) are **out of scope for normal cluster start/stop**. The alfa-ai edge proxy (`alfa-ai-edge-api`) runs on **`inference`** hub (migrated off `apps` Jul 2026).

- The orchestrator `Start-Stop-AlfaAi.ps1` / orchestrator and the hub `operator-cluster-111.sh` explicitly avoid downing these projects.
- **Never** run `docker compose down -v` or equivalent against the `postgres`, `redis`, or `alfa-ai-edge-api` projects.
- Volumes (`alfa-postgres-data`, `alfa-redis-data`, and the edge config bind) are the source of truth for data.

### Top priority sites (never lose data)
- rankings-bot
- alfa website (alfaqd)
- uspbf website
- probilliardssoftware
- alfa-ai itself

These (and others) either:
- Already use their own isolated DB containers inside their compose projects, or
- Use the shared `alfa-*` instances via the dedicated stacks.

### Copying data to per-repo dedicated DBs (for isolation now or per-VM later)

When a repo wants a fully private DB (recommended for long-term per-VM segregation):

1. Bring up a new dedicated Postgres (or reuse the shared one and create a new DB inside it).
2. Use the helper (preferred) or the example below:
   ```bash
   # Recommended helper (safe, no -v, works on apps or hub)
   bash scripts/copy-shared-db-to-per-repo.sh alfaai rankingsbot rankingsbot_user
   ```
3. Update the repo's `.env` (DATABASE_URL) to the new DB.
4. The original data remains untouched.

Manual example (on the DB host):
```bash
docker exec -it alfa-postgres psql -U alfaai -d alfaai -c 'CREATE DATABASE rankingsbot OWNER rankingsbot_user;'
docker exec -it alfa-postgres pg_dump -U alfaai -Fc alfaai | docker exec -i alfa-postgres pg_restore -U alfaai -d rankingsbot --no-owner --no-privileges
```

For full separation later, a repo can run its own Postgres container/VM and import the dump. The dedicated-stack model makes this portable.

See also the backup/restore runbook for verified dump/restore procedures.

**Rule:** never `docker compose ... down -v` (or `rm -fsv`) against `postgres` or `redis` stacks.

## Summary of ownership (both hosts)

- Dedicated stacks own the DB containers/volumes.
- Brain and bot stacks are **consumers only**.
- Edge proxy on `inference` is shared cross-site infra ( admin login; `apps` sites may proxy to it).
- Cluster stop touches inference, brain app processes, pool shards — not the DBs or the `inference` edge.
