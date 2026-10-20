# Start, Stop, and Operations — ALFa AI

**inference full cluster (`orchestrator` orchestrator):** [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) —
use `Start-Stop-AlfaAi.ps1` only for routine start/stop; open `Tail-AlfaClusterHostLogs.ps1` first.

This repo mirrors **rankings-bot** operational patterns: **Docker Compose owns processes**, scripts delegate to `docker compose`, and health is verified with HTTP checks and Compose healthchecks.

**Sibling reference:** [rankings-bot docs/START_STOP_RESTART.md](../../rankings-bot/docs/START_STOP_RESTART.md)

---

## Canonical paths

| Item | Location |
|------|----------|
| Compose file | `deploy/docker-compose.yml` |
| Environment | `deploy/.env` (copy from `deploy/env.example`) — includes `ALFA_WORKER_HEARTBEAT_TOKEN` for Petals worker POST `/api/workers/heartbeat`; **`alfa-ai-api`** uses **`env_file: .env`** so tokens are not lost to empty Compose interpolation (see [SOURCE_OF_TRUTH_AND_SYNC.md](SOURCE_OF_TRUTH_AND_SYNC.md)). |
| External network | `tunnel_network` (create once: `docker network create tunnel_network`) |
| Git + LAN sync | [SOURCE_OF_TRUTH_AND_SYNC.md](SOURCE_OF_TRUTH_AND_SYNC.md) — **`inference`** is cluster hub; **`orchestrator`** pushes to GitHub; **`LITELLM_BASE_URL` inside containers** must be **`http://alfa-ai-litellm:4000`**, not host loopback. |

---

## Primary scripts

| Role | Command |
|------|---------|
| **Start brain (hub) — deps + 27B check + verify** | `sudo bash scripts/start.sh` |
| Rebuild API image then start brain | `sudo bash scripts/start.sh --rebuild` (exports `BUILD_HASH` for both `compose build` and `compose up`; see [MODEL_CONFIG_DRIFT_PREVENTION.md](MODEL_CONFIG_DRIFT_PREVENTION.md)) |
| Start + optional Petals gateway on brain | `sudo bash scripts/start.sh --with-gateway` |
| Start full stack (skip 27B preflight) | `./scripts/start.sh --skip-grev27` |
| Force API rebuild | `./scripts/start.sh --no-cache` |
| Full deploy (rebuild API + brain + verify) | `./scripts/full_deploy.sh` |
| Rebuild API (pull + deps + verify) | `./scripts/brain_redeploy_api.sh` (kept operator script: pull then rebuild). On `hub`: `cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && sudo bash scripts/brain_redeploy_api.sh`. Do not split pull and `--skip-pull`. **Preflight (script-enforced):** Docker daemon (`docker info`) and dedicated `alfa-postgres` / `alfa-redis` must already be running. Brain API / LiteLLM / nginx need **not** be up -- Compose `up` starts them ([compose up](https://docs.docker.com/reference/cli/docker/compose/up/)). Full cluster / inference is **not** required. |
| Pull + API + Missions worker | `./scripts/brain_redeploy_missions.sh` |
| Post-start status (containers + :8420 + 27B) | `./scripts/brain_verify.sh` (auto: local on `hub`, remote on `inference` hub) |
| **Start apps on `apps`** (bots, postgres — no edge) | `bash deploy/cluster-members/apps/boot-all-stacks.sh` |
| **Edge proxy +  admin login (`inference`)** | `bash deploy/cluster-members/_common/start-edge-api.sh` on `inference` — `http://<inference--ip>:8420/alfa-ai/login` |
| Optional one-shot CLI worker (`alfa-ai-worker`, not started by default) | `docker compose --profile agent-worker up -d` from `deploy/` |
| Full deploy, no cache | `./scripts/full_deploy.sh --no-cache` |
| Stop stack (volumes kept) | `./scripts/stop.sh` |
| Stop app only (keep Postgres + Redis) | `./scripts/stop.sh --app-only` |
| Start deps only | `./scripts/start.sh --deps-only` |
| Follow API logs | `./scripts/tail_api_logs.sh` |
| Health check (containers + HTTP) | `./scripts/healthcheck.sh` |
| Port collision preflight (8400–8499 vs rankings-bot) | `./scripts/preflight_ports.sh deploy/.env` |

Shared Compose detection lives in `scripts/_alfa_compose_env.sh` (docker vs `sudo docker`, `deploy/.env`, `COMPOSE_PROGRESS=plain` for readable logs). `alfa_compose_deps_up` fails fast unless dedicated Postgres/Redis containers are running and healthy ([`docker info`](https://docs.docker.com/engine/daemon/troubleshoot/#check-whether-docker-is-running), [`docker inspect`](https://docs.docker.com/reference/cli/docker/inspect/), Postgres [`pg_isready`](https://www.postgresql.org/docs/current/app-pg-isready.html) via the compose healthcheck). Cluster stop does **not** take those DB stacks down ([CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md)).

---

## HTTP health endpoints

| URL | Purpose |
|-----|---------|
| `GET /health` | Liveness (`status` only) |
| `GET /api/health` | Liveness plus `build_hash` (must not stay `local` after a content-hash API build) |
| `GET /api/system/health` | Same (rankings-bot–style discovery name) |

Default host port: `ALFA_AI_API_HOST_PORT` from `deploy/.env` (default **8412**), e.g. `http://127.0.0.1:8412/health`.

---

## Compose healthchecks

Services define Docker **healthcheck** where supported: Postgres, Redis, LiteLLM, Petals gateway, and **alfa-ai-api** (Python `urllib` to `http://localhost:8000/health`). Downstream services use `depends_on: condition: service_healthy` so nginx starts after the API is ready.

---

## Admin and settings

| Topic | Where |
|-------|--------|
| Secrets and ports | `deploy/.env` — `ALFA_AI_JWT_SECRET`, `DATABASE_URL`, `LITELLM_*`, ports |
| Web admin (users, audit, cluster health, IDE) | Log in at `/alfa-ai/` → **Admin** (requires `admin` role) |
| Operator console | `http://<host>:8420/operator/` (see `docs/OPERATOR_CONSOLE.md`) |
| Runtime API token | `ALFA_AI_API_TOKEN` + `ALFA_AI_REQUIRE_API_AUTH` for `/api/runs*` |

---

## Logging

- **API:** `docker logs alfa-ai-api -f` or `./scripts/tail_api_logs.sh`
- **Other services:** `docker logs <container> -f` (e.g. `alfa-ai-litellm`, `alfa-ai-petals-gateway`)

---

## Full deploy vs start

- **`./scripts/start.sh`** — routine bring-up: 27B preflight, build API only if missing (use **`--rebuild`** after code changes), dedicated postgres/redis stacks first (protected), then `up -d --wait` on litellm, api, nginx (via brain compose), then **`brain_verify.sh`**. Does not build optional Petals gateway unless **`--with-gateway`**.
- **`./scripts/full_deploy.sh`** — release-style: sets `BUILD_HASH`, rebuilds images, brings stack up, runs **`./scripts/brain_verify.sh`**. Does **not** automatically apply SQL migrations; apply `infra/db/schema.sql` or your migration tool when the schema changes.

---

## Volumes

`./scripts/stop.sh` / `compose down` **does not** remove named volumes (Postgres/Redis/workspace data) unless you add `-v` manually.
