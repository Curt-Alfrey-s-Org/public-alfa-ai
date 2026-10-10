# Agent worker on gaming-worker-c (gaming-c) — STUB (default off)

Do not start until OpenSSH + Docker are ready and operator opts in.

## When to enable

1. `git pull` on local alfa-ai clone (or SMB stage from `orchestrator`).
2. Copy `env.agent-worker.example` to `.env.agent-worker` and fill secrets.
3. Pull `alfa-ai-app` image from `hub` registry or hub tarball.
4. `docker compose -f docker-compose.agent-worker.yml up -d`

## Env

| Variable | Value |
|----------|-------|
| `ALFA_AI_WORKER_HOST` | `59` |
| `LITELLM_BASE_URL` | `http://hub` |
| `DATABASE_URL` / `REDIS_URL` | Brain on `hub` (LAN) |
| `ALFA_AI_AUDIT_ROOTS` | `alfa-ai=/workspace/alfa-ai` (+ local trees) |

## Judge (separate)

OP-LL-1 judge on `gaming-c` is **not** this worker. Keep `ALFA_AI_JUDGE_ENABLED=0` on brain until judge stack is ready.

## Related

- [docs/MULTI_HOST_AGENT_FLEET.md](../../../docs/MULTI_HOST_AGENT_FLEET.md)
