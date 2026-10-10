# LiteLLM (Proxy + Router)

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.
>
> **Live pin (2026-10-03).** Production compose pins `ghcr.io/berriai/litellm:v1.103.2`
> (GitHub release 2026-10-01, prerelease false). See [STABLE_RELEASES.md](../../STABLE_RELEASES.md)
> and https://docs.litellm.ai/docs/proxy/docker_image_security (numbered `vX.Y.Z` tags only).
> Do not recommend `:latest`, `:main-latest`, or `main-stable`. The "latest stable" section
> below remains a May 2026 research snapshot.

## Official documentation

- **Primary docs URL:** https://docs.litellm.ai
- **Proxy production guide:** https://docs.litellm.ai/docs/proxy/prod
- **Configs reference:** https://docs.litellm.ai/docs/proxy/configs
- **Routing strategies:** https://docs.litellm.ai/docs/routing
- **Load balancing:** https://docs.litellm.ai/docs/proxy/load_balancing
- **Source repo URL:** https://github.com/BerriAI/litellm
- **Release notes:** https://github.com/BerriAI/litellm/releases
- **Docker images:** `ghcr.io/berriai/litellm` (signed via cosign — verify with the keys in https://github.com/BerriAI/litellm/blob/main/cosign.pub)

## Current stable / supported version (as of 2026-05-13)

- **Latest stable:** `v1.83.14-stable.patch.3` (released 2026-05-07). Source: https://github.com/BerriAI/litellm/releases.
- **Pre-release:** `v1.84.0-rc.1` (2026-05-05).
- **EOL policy:** LiteLLM publishes weekly stable + patch releases; older versions are not formally supported. Stable releases are signed and verifiable with `cosign verify --key https://raw.githubusercontent.com/BerriAI/litellm/<commit>/cosign.pub ghcr.io/berriai/litellm:<tag>`. Source: https://github.com/BerriAI/litellm/releases (every release page).

## Key official best practices

- **Production config switch:** set `export LITELLM_MODE="PRODUCTION"` to disable `load_dotenv()` and the dev safety net. Source: https://docs.litellm.ai/docs/proxy/prod (§5).
- **Master key:** require `general_settings.master_key: sk-…` so all `/v1/*` calls must carry `Authorization: Bearer sk-…`. Source: https://docs.litellm.ai/docs/proxy/configs.
- **Salt key:** export `LITELLM_SALT_KEY` once and never change it after models are added — it encrypts API-key credentials in the Postgres DB. Source: https://docs.litellm.ai/docs/proxy/prod (§8).
- **Routing strategies:** valid values are `simple-shuffle` (default, recommended for prod), `least-busy`, `usage-based-routing`, `latency-based-routing`. Set in `router_settings.routing_strategy`. Upstream prod guide explicitly warns against `usage-based-routing` for production. Source: https://docs.litellm.ai/docs/routing.
- **Redis for shared router state:** when running multiple LiteLLM workers/instances, configure `redis_host`, `redis_port`, `redis_password` (NOT `redis_url` — the URL form is documented as ~80 RPS slower per upstream issue #3188). Minimum Redis 7.0. Source: https://docs.litellm.ai/docs/proxy/prod (§4).
- **DB connection pool:** `database_connection_pool_limit = MAX_DB_CONNECTIONS / (instances × workers_per_instance)`. Default 10; recommended 10–20 per worker. Source: https://docs.litellm.ai/docs/proxy/configs ("Configure DB Pool Limits").
- **Disable verbose / Swagger UI in prod:** `litellm_settings.set_verbose: False`, `litellm_settings.json_logs: true`, `export LITELLM_LOG="ERROR"`, optional `NO_DOCS=True` to hide Swagger. Source: https://docs.litellm.ai/docs/proxy/prod and https://docs.litellm.ai/docs/proxy/configs.
- **Worker count:** `--num_workers $(nproc)` matches uvicorn workers to CPU cores. Pair with `--max_requests_before_restart 10000` to mitigate gradual memory growth (use `--run_gunicorn` for the more battle-tested worker recycler). Source: https://docs.litellm.ai/docs/proxy/prod (§3).
- **DB migrations:** in production, set `USE_PRISMA_MIGRATE=True` so LiteLLM uses `prisma migrate deploy` (forward-only, no shadow DB, no drift detection). For Helm/k8s, use a single PreSync hook job and set `DISABLE_SCHEMA_UPDATE=true` on the proxy pods. Source: https://docs.litellm.ai/docs/proxy/prod (§7, §9).
- **Read-only root filesystem:** supported with explicit env vars: `LITELLM_UI_PATH`, `LITELLM_ASSETS_PATH`, `LITELLM_MIGRATION_DIR`, `PRISMA_BINARY_CACHE_DIR`, `XDG_CACHE_HOME`. Source: https://docs.litellm.ai/docs/proxy/prod (§9 — Read-only File System).
- **Fallbacks & retries:** set `litellm_settings.num_retries`, `litellm_settings.fallbacks`, `litellm_settings.context_window_fallbacks`, `litellm_settings.allowed_fails` for resilience across deployments. Source: https://docs.litellm.ai/docs/proxy/configs ("Load Balancing").
- **Image verification:** every release ships with cosign signatures. Producer-recommended verify shape: `cosign verify --key https://raw.githubusercontent.com/BerriAI/litellm/<commit>/cosign.pub ghcr.io/berriai/litellm:<tag>`. Source: https://github.com/BerriAI/litellm/releases.

**v1.103.x startup and SpendLogs (2026-10-03 pin note).** Release notes for v1.103.0 document a startup index on `LiteLLM_SpendLogs` that can slow proxy boot when the table is large. Before recreating or upgrading the `alfa-ai-litellm` container on a brain host with a long-lived `litellm_db`, create the index concurrently on Postgres: `CREATE INDEX CONCURRENTLY "LiteLLM_SpendLogs_api_key_startTime_idx" ON "LiteLLM_SpendLogs" ("api_key", "startTime");` Source: https://docs.litellm.ai/release_notes/v1.103.0/v1-103-0. No in-repo migration script; operators run this once when SpendLogs row count is high.

## Canonical configuration examples

**Production-grade `config.yaml` skeleton** (verbatim shape from https://docs.litellm.ai/docs/proxy/prod):

```yaml
general_settings:
  master_key: sk-...                     # required for prod
  alerting: ["slack"]
  proxy_batch_write_at: 60
  database_connection_pool_limit: 10
  disable_error_logs: True
  allow_requests_on_db_unavailable: True  # only on a private VPC

litellm_settings:
  request_timeout: 600
  set_verbose: False
  json_logs: true
  drop_params: True
  num_retries: 3
  fallbacks: [{"frontier": ["frontier-fallback"]}]
  cache: True
  cache_params:
    type: redis
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    password: os.environ/REDIS_PASSWORD

router_settings:
  routing_strategy: simple-shuffle      # latency-based-routing also valid for fleet load balance
  redis_host: os.environ/REDIS_HOST
  redis_port: os.environ/REDIS_PORT
  redis_password: os.environ/REDIS_PASSWORD
  num_retries: 2
  timeout: 30

model_list:
  - model_name: chat
    litellm_params:
      model: ollama_chat/qwen3-coder:30b-a3b-q4_K_M
      api_base: os.environ/OLLAMA_BASE_URL
      rpm: 60
```

**Container `CMD` (k8s / Compose):** see https://docs.litellm.ai/docs/proxy/prod §3:

```dockerfile
CMD ["--port", "4000", "--config", "./proxy_server_config.yaml", "--num_workers", "$(nproc)", "--run_gunicorn", "--max_requests_before_restart", "10000"]
```

## Common pitfalls / gotchas

- **`redis_url` is ~80 RPS slower than `redis_host`/`redis_port`/`redis_password`.** Use the discrete fields. Source: upstream issue https://github.com/BerriAI/litellm/issues/3188.
- **`usage-based-routing` is documented as not recommended for production.** Source: https://docs.litellm.ai/docs/proxy/prod (§4 warning).
- **Per-worker pool limit multiplies by workers × instances.** Forgetting this overruns Postgres `max_connections`. Source: https://docs.litellm.ai/docs/proxy/configs.
- **Default Swagger UI exposes the master key endpoints.** Set `NO_DOCS=True` in prod. Source: https://docs.litellm.ai/docs/proxy/configs ("Disable Swagger UI").
- **Salt key must be set before adding the first model** — rotating it post-hoc invalidates all stored credentials. Source: https://docs.litellm.ai/docs/proxy/prod (§8).
- **Health-check / readiness path:** `/health/readiness` returns 200 even if the DB is down when `allow_requests_on_db_unavailable: True` — confirm this matches your liveness expectations. Source: https://docs.litellm.ai/docs/proxy/prod (§6).
- **Multiple `model_name: foo` rows = automatic load balance.** This is *the* upstream-recommended way to declare a fleet (e.g. four Ollama hosts behind alias `chat`). Source: https://docs.litellm.ai/docs/proxy/load_balancing.

## Authoritative URLs to cite in our docs

- https://docs.litellm.ai
- https://docs.litellm.ai/docs/proxy/prod
- https://docs.litellm.ai/docs/proxy/configs
- https://docs.litellm.ai/docs/proxy/load_balancing
- https://docs.litellm.ai/docs/routing
- https://docs.litellm.ai/docs/secret
- https://github.com/BerriAI/litellm
- https://github.com/BerriAI/litellm/releases
- https://github.com/BerriAI/litellm/issues/3188

## AUDIT CHECKLIST for the Audit Agent

1. **Master key:** confirm `general_settings.master_key` is set (or `LITELLM_MASTER_KEY` env var) in `deploy/litellm_config.yaml` and `deploy/.env`. Master key on `hub` AND on the `apps` mirror MUST match. Cross-check `deploy/env.example` and `apps-105/env.apps.example`.
2. **Salt key consistency:** `LITELLM_SALT_KEY` must be identical on `hub` and `apps` (both run the brain stack). If they differ, encrypted credentials in `litellm_db` won't decrypt cross-host. Verify in `deploy/env.example` vs `apps-105/env.apps.example`.
3. **Production mode:** confirm `LITELLM_MODE=PRODUCTION` is set in production env files. Without it, `load_dotenv()` runs and may silently override secrets.
4. **Routing strategy:** the cluster uses `latency-based-routing` for the CPU MoE fleet (per `ROADMAP.md` "Idle CPU model serving"). Verify in `deploy/litellm_config.yaml` `router_settings.routing_strategy`. Document in `DISTRIBUTED_AI.md` why it was chosen over `simple-shuffle` for this specific fleet.
5. **Redis usage:** confirm `router_settings` uses `redis_host`/`redis_port`/`redis_password` (NOT `redis_url`) — flag any `redis_url:` in the config. Confirm Redis ≥ 7.0.
6. **Worker count:** confirm `litellm` is invoked with `--num_workers` ≥ CPU cores or with `$(nproc)`. Verify in compose `command:` for `alfa-ai-litellm` service in `deploy/docker-compose.yml`.
7. **DB pool sizing:** verify `database_connection_pool_limit × workers × instances ≤ postgres max_connections`. With two brain hosts (`hub` + `apps`), each running ≥ 4 workers, a pool of 10 = 80 connections — must be < `max_connections` of `alfa-ai` Postgres.
8. **Fallbacks:** verify `frontier` (Petals tier 3a) has a fallback to a CPU MoE fast tier when the swarm is below quorum, and that `fast`/`inline`/`autocomplete` fall back across `orchestrator`/`hub`/`gaming-c`/`gaming-b`. Cross-check against the alias map in `DISTRIBUTED_AI.md` (LiteLLM aliases) and `deploy/litellm_config.yaml` `fallbacks:` entries.
9. **Migration ownership:** with two LiteLLM instances (`hub` and `apps`), only one should run DB migrations at a time. Confirm `USE_PRISMA_MIGRATE=True` is set on a single instance, and `DISABLE_SCHEMA_UPDATE=true` on the other. Verify `deploy/cluster-members/hub/deploy.sh` and the `apps` apps deploy script.
10. **Image verification:** confirm `deploy/docker-compose.yml` pins `ghcr.io/berriai/litellm:v1.103.2` (numbered tag per https://docs.litellm.ai/docs/proxy/docker_image_security) — not `:main-latest` or `:latest` — and that a cosign verification step exists in `deploy/cluster-members/hub/deploy.sh` or a CI gate. On upgrade from an older pin, if `LiteLLM_SpendLogs` is large, apply `LiteLLM_SpendLogs_api_key_startTime_idx` via `CREATE INDEX CONCURRENTLY` before recreate (see v1.103.0 release notes above).
11. **Swagger UI exposure:** confirm `NO_DOCS=True` (or equivalent) is set in production env vars to hide `/`-served Swagger. Verify in `deploy/env.example`.
12. **`/health/readiness` semantics:** if `allow_requests_on_db_unavailable: True`, ensure `nginx` and any external monitoring know that 200 does NOT imply DB-up. Cross-check `deploy/nginx.conf` health probes.
