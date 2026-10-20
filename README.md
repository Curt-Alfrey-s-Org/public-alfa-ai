# ALFa AI (public snapshot)

Open-source snapshot of the ALFa AI **brain**: FastAPI admin API, LiteLLM proxy, and operator UI. You run it on **your** hardware with **your** model endpoints, database passwords, and API keys. This tree is scrubbed; see `docs/PUBLIC_SNAPSHOT.md`.

Production inference in this codebase targets **llama.cpp RPC** (default LiteLLM alias `frontier-code`). You must point `LLAMACPP_CODE27_URL` at an OpenAI-compatible server you control (llama.cpp, vLLM, cloud API, etc.).

## Requirements

- [Docker Engine](https://docs.docker.com/engine/install/) and [Docker Compose v2](https://docs.docker.com/compose/install/) (`docker compose`, not legacy `docker-compose`)
- Enough disk and RAM for Postgres, Redis, and container builds
- A reachable **OpenAI-compatible** inference URL for chat (see env below)

## Configure (one time)

From the repo root:

```bash
cp config/hosts.example.env config/hosts.env
cp deploy/env.example deploy/.env
```

Edit `config/hosts.env` with **your** hostnames or documentation IPs (do not commit).

Edit `deploy/.env`. Replace every `change-me` and set **your** values at minimum:

| Variable | Purpose |
|----------|---------|
| `ALFA_POSTGRES_PASSWORD`, `POSTGRES_PASSWORD` | Postgres (same value) |
| `REDIS_PASSWORD` | Redis auth |
| `DATABASE_URL` | e.g. `postgresql://alfaai:change-me@alfa-postgres:5432/alfaai` |
| `REDIS_URL` | e.g. `redis://:change-me@alfa-redis:6379/0` |
| `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `LITELLM_API_KEY` | LiteLLM (use long random strings) |
| `ALFA_AI_JWT_SECRET` | Web login sessions |
| `ALFA_AI_API_TOKEN` | Bearer token when `ALFA_AI_REQUIRE_API_AUTH=true` |
| `LLAMACPP_CODE27_URL` | **Your** model base URL (e.g. `http://host.docker.internal:31360/v1`) |
| `LLAMA_API_KEY` | **Your** key the model server expects (often `change-me` for local llama.cpp) |
| `EMBED_BASE_URL`, `RERANK_BASE_URL` | Optional RAG sidecars on **your** rag host |

Optional cloud keys: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `HF_TOKEN`. Public site URL: `ALFA_AI_PUBLIC_URL=https://example.com`.

Never commit `deploy/.env` or `config/hosts.env`.

## Start the stack

Create the external network once ([Compose networking](https://docs.docker.com/compose/how-tos/networking/)):

```bash
docker network create tunnel_network
```

Start Postgres and Redis, apply schema, then start the brain ([Compose CLI](https://docs.docker.com/reference/cli/docker/compose/up/)):

```bash
cd deploy
docker compose --env-file .env -f docker-compose.postgres.yml up -d
docker compose --env-file .env -f docker-compose.redis.yml up -d
cd ..
bash scripts/ensure-runtime-schema.sh
bash scripts/start.sh --skip-grev27 --rebuild
```

`--skip-grev27` skips waiting for a llama.cpp RPC coordinator when you have not deployed one yet. Remove it once your model URL answers `/health`.

First build can take several minutes (API image includes the frontend).

## Verify, logs, stop

| Check | URL or command |
|-------|----------------|
| API liveness | `http://127.0.0.1:8412/health` |
| LiteLLM | `http://127.0.0.1:8413/health/liveliness` |
| Operator UI | `http://127.0.0.1:8420/operator/` |
| Automated checks | `bash scripts/brain_verify.sh --skip-grev27` |
| API logs | `bash scripts/tail_api_logs.sh` |
| Stop brain (keep DB) | `bash scripts/stop.sh` |

Ports come from `deploy/.env` (`ALFA_AI_*_HOST_PORT`; defaults 8412, 8413, 8420).

## Layout

| Path | Role |
|------|------|
| `src/` | Python API and services |
| `deploy/docker-compose.yml` | Brain: LiteLLM, API, nginx |
| `deploy/docker-compose.postgres.yml`, `deploy/docker-compose.redis.yml` | Data stores |
| `scripts/start.sh` | Start brain after DBs are up |
| `infra/db/schema.sql` | SQL baseline (applied via `scripts/ensure-runtime-schema.sh`) |
| `docs/` | Operator and architecture notes |

## Multi-host (advanced)

If you run hub, rag, and GPU shards on separate machines, use role names only in `config/hosts.env`. On a Windows **orchestrator** host, start and stop the full cluster with one script (no manual shard restarts):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start
```

Details: `docs/CLUSTER_START_STOP_OPERATOR.md`, `docs/START_STOP_AND_OPERATIONS.md`.

## Safety

- Set `ALFA_AI_REQUIRE_API_AUTH=true` and a strong `ALFA_AI_API_TOKEN` if the API is reachable beyond localhost.
- Agent filesystem and command tools respect `ALFA_AI_WORKSPACE_ROOT` and timeouts in `deploy/env.example`.

## License

MIT — see `LICENSE`.
