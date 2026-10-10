# Self-Hosted Deployment Baseline

## Purpose

Provide a standard deployment baseline for ALFa AI using Docker Compose + nginx + Postgres + Redis, aligned with workspace network/security rules.

## Standards Applied

- Shared external network name remains `tunnel_network`.
- API host port mapping uses `127.0.0.1:HOSTPORT:CONTAINERPORT`.
- UI/nginx host mapping also uses `127.0.0.1:HOSTPORT:CONTAINERPORT`.
- API process binds `0.0.0.0` inside containers.
- Service-to-service calls use Docker DNS (`alfa-ai-api:8000`), not host loopback.
- Postgres and Redis stay on private app network only.

<!-- iofix-2026-06-19-deploy-standards -->
- App DB storage (Postgres/Redis) is placed on the host's fast pool via
  `ALFA_AI_PG_DATA_PATH` / `ALFA_AI_REDIS_DATA_PATH` (blank = Docker named volume
  default; absolute path = bind mount). See
  [HOST_STORAGE_AND_NETWORK_STANDARDS.md](HOST_STORAGE_AND_NETWORK_STANDARDS.md) S1.

## Files

- `deploy/docker-compose.yml`
- `deploy/docker-compose.ollama-gpu.yml` (optional; GPU Ollama in Docker — see `docs/ALFA_AI_DOCKER_RUNBOOK.md`)
- `deploy/nginx/conf.d/default.conf`
- `deploy/env.example`

## Network Topology

- `alfa-ai-network` (private): api, worker, postgres, redis, nginx.
- `tunnel_network` (external shared ingress): api and nginx only.

## Runtime Ownership

Single process owner per service/port:

- Docker Compose services own startup/restart lifecycle.
- No secondary scripts should separately start the same API process/port.
- When Compose publishes **`alfa-ai-api`**, run **`scripts/preflight_api_ownership.sh compose-will-manage-api`** immediately before **`docker compose ... up`** (wired into **`deploy/cluster-members/hub/deploy.sh`** and **`deploy/cluster-members/apps/deploy.sh`**). Emergency bypass: **`ALFA_AI_SKIP_API_OWNERSHIP_CHECK=1`** (automation only).

### April 2026 cluster deployment: brain on `hub`, apps on `apps`

This baseline applies to the **brain host** (`hub` hub Scale 25.04).
Other nodes have role-specific deploy guides:

- `hub` brain → [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md)
- `apps` remaining apps → [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md)
- `orchestrator` Dockge UI + inference shard + orchestrator → `deploy/cluster-members/orchestrator/deploy.ps1`
- inference shards → [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md)

On the brain host (`hub`), the `alfa-ai-api` **runs via Docker Compose** (not
systemd). The `deploy/systemd/alfa-ai-api.service` unit is a legacy path
from the `apps`-brain era — do not enable it on `hub`.

### Hybrid: systemd API on the host + LiteLLM in Docker (legacy `apps` setup)

If a host has **`alfa-ai-api`** served by **systemd** (see
`deploy/systemd/alfa-ai-api.service`) on **127.0.0.1:8412**, **do not** start
the **`alfa-ai-api`** Compose service — it would fail to bind the same host
port. This hybrid was used on `apps` pre-migration and is no longer the
cluster default.

```bash
cd /home/operator/alfa-ai/deploy
docker compose --env-file .env -f docker-compose.yml up -d alfa-ai-litellm
```

Use **`./scripts/preflight_ports.sh .env --allow-in-use`** when **8412** is
expected to be the running API (systemd owns the API). Before switching to
Compose **`alfa-ai-api`**, stop/disable systemd and run
**`./scripts/preflight_api_ownership.sh compose-will-manage-api`**.

Ensure **Ollama** is reachable at
**`OLLAMA_BASE_URL`** from inside the LiteLLM container (`host.docker.internal`
on Linux per compose, or the LAN IP when Ollama runs as a separate
hub App on `hub`).

## Startup (on `hub` brain host)

1. Review `docs/PORT_ASSIGNMENTS.md`.
2. Copy `deploy/env.example` to `deploy/.env` and adjust values. Key values
   on `hub`:
   - `ALFA_AI_API_HOST_PORT=8420` (container `8000`)
   - `ALFA_AI_LITELLM_HOST_PORT=8413` (container `4000`; external callers use `8413`)
   - `LLAMACPP_CODE27_URL=http://host.docker.internal:31360/v1` — inference
     coordinator on **`hub:31360`**. Do not set `LLAMACPP_FRONTIER_URL` on `orchestrator`.
   - `EMBED_BASE_URL=http://orchestrator` and
     `RERANK_BASE_URL=http://orchestrator` (CPU RAG on **`rag`**).
   - Do **not** set `PETALS_GATEWAY_*` or `OLLAMA_FLEET_*` (retired).
   - `DEFAULT_MODEL=frontier-code` (27B RPC pool; 35B MoE and Petals 70B retired).
     SSoT: [DOCUMENTATION_CANONICAL.md](DOCUMENTATION_CANONICAL.md).
   - DBs run in **protected dedicated stacks** (`postgres`/`redis` via split compose files
     in `stackshub.yml` on `hub`; same on `apps` via `stacksapps.yml`). Configure data
     paths for the dedicated stacks (e.g. `ALFA_POSTGRES_DATA_PATH`). The brain compose
     does not define DB services. Set `DATABASE_URL`/`REDIS_URL` to target the dedicated
     containers (Docker DNS) or external. Never `-v` the dedicated DB stacks.
3. Ensure `tunnel_network` exists.
4. Run port preflight:
   - `./scripts/preflight_ports.sh deploy/.env`
5. Run API ownership preflight (Compose will publish **`alfa-ai-api`**):
   - `bash scripts/preflight_api_ownership.sh compose-will-manage-api`
6. Run:
   - `docker compose --env-file deploy/.env -f deploy/docker-compose.yml up -d`
7. Validate:
   - `curl http://127.0.0.1:8420/health`
   - `curl http://127.0.0.1:8080/health` (nginx)
   - Optional: `./scripts/alfa_ai_rollout_preflight.sh deploy/.env` (add
     `--strict` before production); full phased order:
     [rankings-bot ALFA_AI_MULTI_JOB_ROLLOUT.md](../../rankings-bot/docs/ALFA_AI_MULTI_JOB_ROLLOUT.md).

## Notes

- Host ports in `deploy/env.example` are defaults; choose approved free ports before production use.
- For internet-facing deployment through Cloudflare tunnel, route traffic to `alfa-ai-nginx:80` on `tunnel_network`.


<!-- iofix-2026-06-19-deploy-notes -->
- Per-host DB paths live only in `deploy/.env` (gitignored). On `hub`:
  `ALFA_AI_PG_DATA_PATH=/mnt/ssd/alfa-ai/postgres`,
  `ALFA_AI_REDIS_DATA_PATH=/mnt/ssd/alfa-ai/redis`. Hosts that leave these blank
  keep the original named-volume behavior — safe to commit fleet-wide.
