# Multi-host agent fleet (1B workers + hub analysis)

Each cluster host runs its own **`alfa-ai-worker`** container that drains
**host-affinity** tasks from the brain orchestrator on `hub`. Workers call
**LiteLLM on `hub`** (`:8413` / `frontier-code`) for LLM steps; findings land in
shared Postgres + hub `agent-audit-logs/` for export and **Cursor** review.

**Judge:** `ALFA_AI_JUDGE_ENABLED=0` until OP-LL-1 on `gaming-c`. Cursor judges via
`cursor-review-*.md`.

**Autonomy:** L1 read-only gather + propose. Mutate stays L2 / off.

## Topology

```text
Feeder (hub) --POST /api/runs target_host--> Orchestrator (Postgres + Redis)
     |                                              |
     |                    alfaai:queue:tasks:{host}   |
     v                                              v
worker apps  worker probilliards  worker hub  ...     LiteLLM hub
     |              |            |
     +--------------+------------+--> hub agent-audit-logs + Missions UI
```

## Host affinity

| Env | Role |
|-----|------|
| `ALFA_AI_WORKER_HOST` | This worker's id (`111`, `105`, `106`, ...) |
| `target_host` on `POST /api/runs` | Routes task to `alfaai:queue:tasks:{host}` |
| Empty / omitted `target_host` | Defaults to **`111`** (brain hub worker) |

Workers **only** pop their own queue. A `apps` worker never claims a `probilliards` task.

## Per-host worker env (required)

| Variable | Remote worker example |
|----------|----------------------|
| `ALFA_AI_WORKER_HOST` | `105` |
| `DATABASE_URL` | `postgresql://alfaai@hub/alfaai` (LAN brain Postgres) |
| `REDIS_URL` | `redis://hub/0` |
| `LITELLM_BASE_URL` | `http://hub` |
| `ALFA_AI_AUDIT_ROOTS` | Repos **on this host only** (see matrix below) |

Bind-mount audit roots read-only into the container at paths matching `AUDIT_ROOTS`.

## AUDIT_ROOTS matrix (always-on)

| Host | `ALFA_AI_WORKER_HOST` | Example `ALFA_AI_AUDIT_ROOTS` |
|------|----------------------|--------------------------------|
| `hub` | `111` | `alfa-ai=/workspace/alfa-ai` |
| `apps` | `105` | `contracts-bot=/repos/contracts-bot,alfaqd-website=/repos/alfaqd-website` |
| `market` | `102` | `market-pie5-bot=/repos/market-pie5-bot` |
| `atems` | `103` | `atems=/repos/atems` |
| `probilliards` | `106` | `rankings-bot=/repos/rankings-bot,uspbf=/repos/USPBF` |
| `monitor` | `107` | `monitoring=/repos/monitoring` |
| `inference` | `148` | `alfa-ai=/repos/alfa-ai` |
| `pool-opt-in` | `100` | `alfa-ai=/repos/alfa-ai` |

Gaming (`gaming-c`, `gaming-a`, `gaming-b`): stubs in `deploy/cluster-members/*/AGENT_WORKER.md` —
**default off** until operator enables.

## Skills

| Skill | Purpose |
|-------|---------|
| `audit-repo` | Repo text audit (existing) |
| `host-facts` | Local processes, docker, disk/mem, allowlisted log grep |
| `error-cataloger` | Roll up errors (brain / any host) |

## Hub reporting

- Central export on `hub`: `export_audit_findings.py` tags jsonl with `target_host`.
- Optional NFS path: `agent-audit-logs/hosts/{host}/` when mount present.
- **Admin Missions** tab shows per-host worker fleet cards + heartbeats.

## Deploy order

1. `hub` brain redeploy with `ALFA_AI_WORKER_HOST=111` on existing worker.
2. **LAN data plane (required for remote workers):** on `hub` `deploy/.env` set
   `ALFA_AI_POSTGRES_LAN_BIND=hub` and `ALFA_AI_REDIS_LAN_BIND=hub`,
   then run `bash scripts/open_lan_db_for_workers.sh` (dual loopback + LAN bind via
   `docker-compose.*.lan-bind.yml`; firewall: LAN `orchestrator/24` only).
   Run `bash scripts/bootstrap_agent_worker_brain.sh` to publish the app image tarball
   and hub secrets file (`/mnt/cluster/agent-worker-brain.env`).
3. One always-on Linux host at a time: NFS mount if needed, then
   `bash scripts/deploy_remote_agent_worker.sh deploy/cluster-members/<member>`.
4. Verify **Admin -> Missions** shows worker `alive` for that host.
5. Gaming: follow member `AGENT_WORKER.md` when ready (judge on `gaming-c` is separate).

## Related

- [ADMIN_MISSIONS.md](ADMIN_MISSIONS.md)
- [operations/SCHEDULED_AUDIT_MISSIONS.md](operations/SCHEDULED_AUDIT_MISSIONS.md)
- [REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md)
- [AI_AUTONOMY_AND_OVERSIGHT.md](AI_AUTONOMY_AND_OVERSIGHT.md)
