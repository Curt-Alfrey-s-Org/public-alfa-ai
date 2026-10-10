# Wait / poll after service start — operator and deploy standard

**Problem:** One-shot `curl` immediately after `docker compose up`, `restart`, or
`--force-recreate` often fails while the container is `(health: starting)` —
Prisma migrations, model preload, or WSL bind lag. That is **not** a deploy failure;
it is a missing poll step.

**Rule:** Any sequence that **starts** a service and then **probes** `/health` (or
`/health/liveliness`) must call a **wait helper** between start and probe.

## Shared helpers (`deploy/cluster-members/_common/`)

| Script | Use after | Default URL / port |
|--------|-----------|-------------------|
| [`wait-http.sh`](../deploy/cluster-members/_common/wait-http.sh) | Generic HTTP 2xx poll | argument |
| [`wait-litellm-liveliness.sh`](../deploy/cluster-members/_common/wait-litellm-liveliness.sh) | `alfa-ai-litellm` recreate/up | `127.0.0.1:8413/health/liveliness` |
| [`wait-brain-health.sh`](../deploy/cluster-members/_common/wait-brain-health.sh) | Brain API stack up | `127.0.0.1:8420/health` |
| [`wait-petals-gateway-health.sh`](../deploy/cluster-members/_common/wait-petals-gateway-health.sh) | **Retired** — do not start a Petals gateway | historical `:8413/health` |
| [`wait-petals-gateway-health.ps1`](../deploy/cluster-members/_common/wait-petals-gateway-health.ps1) | **Retired** — do not start a Petals gateway | historical |
| [`Wait-AlfaHttpPoll.ps1`](../deploy/cluster-members/_common/Wait-AlfaHttpPoll.ps1) | Generic (Windows) | argument |

Defaults: **timeout 120s**, **interval 5s** (gateway preload on `orchestrator` may use **180s**).

## Operator paste blocks (correct pattern)

**LiteLLM recreate on `hub`:**

LiteLLM depends on **`alfa-ai-redis`** (response cache in `litellm_config.yaml`) and
**`alfa-ai-postgres`** (Prisma). Start both **before** recreating LiteLLM, or use
`deploy/cluster-members/hub/deploy.sh` for the full brain stack.

```bash
setopt interactivecomments
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
sudo docker compose --env-file .env up -d alfa-ai-redis alfa-ai-postgres
sudo docker compose --env-file .env up -d --force-recreate alfa-ai-litellm
bash ../deploy/cluster-members/_common/wait-litellm-liveliness.sh 120
```

Do **not** put a one-shot `curl` immediately after `up` without the wait line.
If liveliness times out, check `docker ps` for redis/postgres and
`sudo docker logs --tail=100 alfa-ai-litellm`.

**Petals gateway on `orchestrator`:** retired. Do not poll `orchestrator:8413/health` for Petals.
Live LiteLLM is **`hub:8413`** — use `wait-litellm-liveliness.sh` after brain
recreate.

## Rollout checklist

Track in [`.cursor/plans/WAIT_POLL_ROLLOUT.md`](../.cursor/plans/WAIT_POLL_ROLLOUT.md).

| Phase | Scope | Status |
|-------|--------|--------|
| **1** | `_common` wait scripts; `hub-111/deploy.sh` smoke; `wait-petals-gateway-health.ps1` in `deploy.ps1`; DOCKGE_111 + ROADMAP + cursor rules | **Done** (this doc) |
| **2** | `DOCKGE_105_OPERATOR.md`, `apps-105/deploy.sh`, post-startup status scripts, `DOCUMENTATION_CANONICAL` verification block | Pending |
| **3** | All `operator-93` / Windows member README smoke sections; `deploy-petals-gateway.ps1` docs | Pending |
| **4** | Monitoring blackbox / Grafana probe docs; CI smoke if added | Pending |
| **5** | Audit remaining `sleep N` + `curl` pairs in repo (`rg 'sleep.*curl'` / manual) | Pending |

## Agent / doc authoring

When writing **multi-command operator blocks** or deploy scripts:

1. If command A starts a container and command B hits `/health` → insert the matching **wait-** script between them.
2. Prefer **shared helpers** over inline `for i in $(seq …); do curl …`.
3. Never use bare `sleep 2` as a substitute for health poll in deploy smoke tests.

Cursor rule: `alfa-ai/.cursor/rules/operator-health-poll-after-start.mdc`.
