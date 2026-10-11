# ALFa AI (public snapshot)

Local LLM brain. Production inference is llama.cpp RPC. The default alias is `frontier-code`. LiteLLM on the hub sends that alias to the llama.cpp coordinator. Petals is retired. Ollama is not the production path.

This tree is a scrubbed snapshot. See `docs/PUBLIC_SNAPSHOT.md`.

## Production shape

Use role names. Do not put live addresses in git.

| Role | Role in this stack |
|------|--------------------|
| hub | Brain, Postgres, Redis, and LiteLLM. The llama.cpp RPC coordinator listens on port 31360. |
| rag | Embed on port 11435 and rerank on port 8360. |
| orchestrator | Start and stop only. |

Ports on the hub:

| Service | Port | Where it listens |
|---------|------|------------------|
| API | 8412 | localhost |
| LiteLLM | 8413 | hub host |
| Operator console | 8420 | hub host (`/operator/`) |
| llama.cpp RPC coordinator | 31360 | hub host |

Postgres and Redis are on the hub, in `deploy/docker-compose.postgres.yml` and `deploy/docker-compose.redis.yml`.

## Configure before you run

1. Docker on the hosts you control.
2. Copy `config/hosts.example.env` to `config/hosts.env`. Do not commit `hosts.env`.
3. Copy `deploy/env.example` to `deploy/.env`. Set `DEFAULT_MODEL=frontier-code`. Point `LLAMACPP_CODE27_URL` at the coordinator on the hub, port 31360. Point `EMBED_BASE_URL` at the rag host, port 11435, and `RERANK_BASE_URL` at the rag host, port 8360. Never commit `.env`.

## Start and stop

On the orchestrator, use only `deploy/cluster-members/orchestrator/Start-Stop-AlfaAi.ps1`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 stop
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start
```

Do not start or stop individual shards by hand.

## Safety

Filesystem tools stay inside `ALFA_AI_WORKSPACE_ROOT`. Commands time out (`ALFA_AI_COMMAND_TIMEOUT_SEC`). If the API is reachable beyond localhost, set `ALFA_AI_REQUIRE_API_AUTH=true` and a local `ALFA_AI_API_TOKEN`.

## Layout

- `src/` application code
- `deploy/` compose files and env examples
- `docs/` notes for this snapshot
