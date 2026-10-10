# Admin Missions tab (agent fleet control plane)

Read-only oversight in the www Admin SPA for **background agent jobs** (auditors,
feeders, judges, orchestrator runs). This is **not** Docker Health (app containers)
and **not** Ask ALFa host actions (AI Actions tab).

**Autonomy:** L1 observe in this tab ([AI_AUTONOMY_AND_OVERSIGHT.md](AI_AUTONOMY_AND_OVERSIGHT.md)).
**Mutating control** (enqueue a mission, pause/resume the audit feeder) is **chat-first**
via **Ask ALFa** — same Approve/Reject cards as host actions
([ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md)).

## Chat-first control (Ask ALFa)

Missions are for **feeder pause/resume**, **clear stuck**, and **scheduled background jobs**.
**Audit host N**, **Review errors**, and **Run host-facts on host N** inspect in **Ask ALFa**
(this chat: pre_inspect + LLM reply). **Not** everyday Q&A — `research online`, zip weather,
and HA/solar weather are **Ask ALFa inspect + LLM in this dock** ([AI_ACTIONS.md](AI_ACTIONS.md)
chat pipe). Requests like `analyze|inspect|look at <repo>` go to the **inspect-then-act**
loop in chat and do **not** open the Missions tab.

| You say | What happens |
|---------|----------------|
| `Fleet status` | Read-only worker/feeder summary |
| `What jobs were completed overnight?` | Activity summary (no LLM); overnight = 12h of completed missions |
| `Audit all hosts` | Lists every enabled worker with example `Audit host N` phrases (each inspects in Ask ALFa) |
| `Audit host 102` / `148` / `111` / ... | **Ask ALFa inspect + LLM** on that host (`git_status`, `docker_ps`, …) — reply in this chat |
| `Review errors in alfa-ai and list them` | **Ask ALFa inspect + LLM** from packed errors/incidents context — reply in this chat |
| `Run host-facts on host 105` | **Ask ALFa inspect + LLM** (`docker_ps`, `docker_stats`, …) on that host |
| `Pause audit feeder` / `Resume audit feeder` | Proposes feeder control on `hub` — **Approve** to enqueue |

**Enabled mission targets:** `hub`, `apps`, `market`, `atems`, `probilliards`, `monitor`, `inference`, `pool-opt-in`
(gaming stubs `gaming-c`/`gaming-a`/`gaming-b` off until enabled).

After Approve on enqueue: chat shows `run_id=...` and an **Open Missions** button;
select that run for **Live tool events** (SSE). Host SSH actions show terminal
output directly in chat.

The LAN operator console (`:8420/operator/`) remains for scripts/emergencies.

## Terminology (UI copy)

| UI label | Meaning |
|----------|---------|
| **Fleet** | Registered mission/job types (auditor, judge, feeder, ...) |
| **Runs** | `POST /api/runs` orchestrator missions |
| **Side processes** | Host loops outside Docker (day-session feeder/export/judge) |
| **Artifacts** | Hub outputs under `agent-audit-logs/` |

## API (admin JWT only)

All routes require `Authorization: Bearer <access JWT>` and admin role.
Network allowlist: same as other `/alfa-ai/api/admin/*` routes.

| Method | Path | Behavior |
|--------|------|----------|
| GET | `/alfa-ai/api/admin/missions/fleet` | Catalog + heartbeats + active/done run counts per skill |
| GET | `/alfa-ai/api/admin/missions/runs` | List runs (newest first; `?limit=50`) |
| GET | `/alfa-ai/api/admin/missions/runs/{run_id}` | Run + tasks + artifacts + usefulness |
| GET | `/alfa-ai/api/admin/missions/runs/{run_id}/events` | SSE mission events (`?access_token=` for EventSource) |
| GET | `/alfa-ai/api/admin/missions/artifacts/summary` | Today's hub findings/judge/cursor summary |
| GET | `/alfa-ai/api/admin/missions/findings` | Severity-sorted findings inbox + proposed `would_take_action` (L1 propose-only) |
| GET | `/alfa-ai/api/admin/missions/wedge` | Stuck-run / missing-feedback wedge report (L1 observe) |
| POST | `/alfa-ai/api/admin/missions/clear-stuck` | Mark wedged runs failed (`?dry_run=true` optional) |
| GET | `/alfa-ai/api/admin/missions/worker` | `alfa-ai-worker` liveness from running tasks |

## Findings inbox (severity + would-take)

The Missions tab **Findings** panel lists issues from today's hub export
(`findings-YYYY-MM-DD.md`), merged with `judged.jsonl` when present.

| Field | Meaning |
|-------|---------|
| `severity` | `critical` / `high` / `bug` / `medium` / `suggestion` / `low` / `nit` (sorted critical→nit) |
| `description` | What the auditor reported |
| `file` | Path:line when known |
| `would_take_action` | Proposed corrective step (**not** executed). Source: Finding `Suggestion:` or a deterministic gap action |
| `would_auto_apply` | Always `false` (L1 observe / propose only — human gate) |
| `judge_verdict` | `confirm` / `revise` / `reject` / skipped when judge ran |

**Audit → UI path:** `audit-repo` must emit `### Finding N - Severity:` blocks
([skills/audit-repo/SKILL.md](../skills/audit-repo/SKILL.md)) → day-session export →
optional judge → this inbox. When today's markdown has no structured Finding blocks,
**pipeline gap** rows surface failed exports and zero-artifact runs from `findings.jsonl`.

**Pipeline-gap date filter (UTC):** gap rows are included only for **today (UTC)**. A
`findings.jsonl` record qualifies when any of: `exported_at` is today's UTC date,
`markdown_path` basename is `findings-YYYY-MM-DD.md` for today, or its `run_id` appears in
today's `findings-YYYY-MM-DD.md`. Older jsonl rows (e.g. prior months) are excluded so the
inbox is not flooded with stale failures when no export ran today.

**Corrective-analyst** (separate skill) turns `errors.jsonl` into `corrective_actions.md`
with proposed steps; those are mission artifacts, not auto-applied.

## Mission wedge (stuck / missing feedback)

ALFa expects terminal run status (`done`/`failed`) and structured `### Finding` blocks
after audits. When feedback is missing, Ask ALFa and `GET /missions/wedge` report a
**wedge**:

| Signal | Meaning |
|--------|---------|
| Stuck runs | `pending`/`running` older than `ALFA_AI_MISSION_STUCK_SEC` (default 1800) |
| Feeder blocked | Active runs >= `ALFA_AI_AUDIT_MAX_ACTIVE` |
| Duplicate goals | Same goal active multiple times (repeat enqueue without completion) |
| Missing findings | Done audits today but zero structured Finding blocks |
| Worker gaps | Active run targets a worker with stale/unknown heartbeat |

**Chat:**

| Phrase | Effect |
|--------|--------|
| `Are missions wedged?` / `Mission health` | Read-only wedge report + would-take steps |
| `Clear stuck missions` | Propose `mission_clear_stuck` (Approve marks wedged runs failed) |
| Activity summary | Includes mission queue health at the top |

Clearing stuck runs is **L2 Approve** (does not touch inference). After clear, re-enqueue
`audit-repo` once workers are healthy.

## Fleet catalog (code)

Static registry in `src/ops/mission_fleet.py`:

| id | kind | skill / process |
|----|------|-----------------|
| `audit-repo` | skill | `audit-repo` |
| `error-cataloger` | skill | `error-cataloger` |
| `corrective-analyst` | skill | `corrective-analyst` |
| `sleep-curator` | skill | `sleep-curator` |
| `host-facts` | skill | `host-facts` |
| `day-session` | side_process | `run_audit_day_session.sh` |
| `day-session-feeder` | side_process | `audit_mission_feeder.sh` |
| `export-findings` | side_process | `export_audit_findings.py` |
| `judge-findings` | side_process | `judge_audit_findings.py` |

Skill entries show run counts from the orchestrator store. Side-process entries
merge heartbeat JSON from the hub log dir. **Worker host** entries use Redis
heartbeats (`alfa-ai-worker-{host}`).

## Heartbeats

Side processes write:

`{ALFA_AI_AUDIT_LOG_DIR}/heartbeats/{name}.json`

Example:

```json
{"name":"export-findings","pid":12345,"updated_at":"2026-07-12T14:30:00+00:00","last_action":"export ok new_exports=2","status":"alive"}
```

| name | Writer |
|------|--------|
| `day-session` | `scripts/run_audit_day_session.sh` (each loop) |
| `day-session-feeder` | `scripts/audit_mission_feeder.sh` |
| `export-findings` | `scripts/export_audit_findings.py` |
| `judge-findings` | `scripts/judge_audit_findings.py` |

Status in API/UI:

- **alive** — heartbeat younger than stale threshold
- **stale** — heartbeat exists but too old
- **idle** — heartbeat `status` field is `idle`
- **unknown** — no heartbeat file

Stale thresholds (seconds): feeder 5400, export 1200, judge 1200, day-session 3600.

## Hub mount (API container)

`alfa-ai-api` bind-mounts hub logs read-only:

```yaml
${ALFA_AI_AUDIT_LOG_DIR:-/mnt/HDDs/Alfa-AI/agent-audit-logs}:/var/alfa-ai/agent-audit-logs:ro
```

Inside the container: `ALFA_AI_AUDIT_LOG_DIR=/var/alfa-ai/agent-audit-logs`.

## Usefulness / idle-burn flag

Run detail and fleet summary include:

- `tool_event_count` — from in-memory mission event bus for the run
- `artifact_count` — orchestrator artifacts
- `finding_count` — `### Finding` blocks in exported markdown when present
- `likely_idle_burn` — run `done`, zero findings, zero artifacts, and
  `tool_event_count` >= `IDLE_BURN_TOOL_THRESHOLD` (default **10**, code constant)

## Deploy

**One-shot on `hub` (preferred after push from owning clone):**

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash scripts/brain_redeploy_missions.sh
```

That script: `git pull --ff-only` → **re-exec** the pulled script →
`brain_redeploy_api.sh` → start `alfa-ai-worker` (compose profile
`agent-worker`) → `docker ps` + recent logs. Docker uses `sudo docker` when
`operator` cannot talk to the daemon without sudo (see
`scripts/_alfa_compose_env.sh`). It **tees a timestamped log** under
`/mnt/HDDs/Alfa-AI/agent-audit-logs/brain-redeploy/`. Push SCP from `hub` to
`orchestrator` is **off by default** (Windows OpenSSH inbound from hub often times
out). On `orchestrator`, pull the latest log:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pull-brain-redeploy-log-from-111.ps1
```

Optional push: `--scp` or `SCP_TO_93=1` (expect `SCP_FAIL` unless OpenSSH Server
on `orchestrator` accepts `operator`). Flags: `--skip-pull`, `--skip-redeploy`,
`--worker-only`, `--scp`, `--no-scp`. Env: `SCP_HOST`, `SCP_REMOTE_DIR`,
`SCP_IDENTITY`.

### Post-redeploy monitoring

After a successful API recreate (`brain_redeploy_api.sh` or step 2 of
`brain_redeploy_missions.sh`):

1. **`monitor` (monitoring):** `brain_redeploy_api.sh` attempts SSH to refresh the
   Prometheus admin bearer so `alfa-ai-incident-metrics` stays **up**. Cluster
   start from `orchestrator` always retries after brain health. If refresh returns
   **401**, the refresh token is dead -- see recovery in
   [ALFA_AI_OPERATIONAL_ALERTS.md](ALFA_AI_OPERATIONAL_ALERTS.md)
   (re-login and re-save both tokens, or mint inside `alfa-ai-api`; never restart
   Prometheus). Manual on `monitor` if SSH from `hub` is not configured:

   ```bash
   cd /home/operator/monitoring
   bash scripts/refresh-alfa-ai-prometheus-bearer.sh
   ```

2. **`hub` (if Postgres/Redis alerts flap):** ensure dual loopback + LAN bind —
   `bash scripts/open_lan_db_for_workers.sh` (see [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md)).

Manual steps (same order):

1. Commit/push from owning clone (`orchestrator` / `pool-opt-in`).
2. Every brain clone: `git pull --ff-only origin main`.
3. `hub`: `brain_redeploy_api.sh` (new mount + routes).
4. `hub`: `docker compose --profile agent-worker up -d alfa-ai-worker`.
5. Admin SPA: **Missions** tab → Findings by severity.

## Chat-first mission control (Ask ALFa)

Operators can drive the mission fleet from **Ask ALFa** without opening the operator
console. Deterministic chips (no LLM):

| Operator phrase | Effect |
|-----------------|--------|
| Fleet status | Read-only summary from `missions_fleet` context |
| What jobs were completed overnight? | Activity summary (no LLM); overnight = 12h window of `done`/`failed` runs |
| Audit host N | **Ask ALFa inspect + LLM** on host N (pre_inspect SSH reads, reply in chat) |
| Review errors | **Ask ALFa inspect + LLM** from packed admin errors/incidents (no SSH) |
| Run host-facts on host N | **Ask ALFa inspect + LLM** on host N (`docker_ps`, `docker_stats`, …) |
| Pause audit feeder | Propose `mission_feeder_pause` on `hub` (creates `FEEDER_PAUSE`) |
| Resume audit feeder | Propose `mission_feeder_resume` on `hub` |

After Approve on `mission_enqueue`, stdout includes the `run_id` and a reminder to open
**Admin -> Missions** and select the run for live tool-event SSE.

Feeder pause file: `{ALFA_AI_AUDIT_LOG_DIR}/FEEDER_PAUSE` (honored by
`scripts/audit_mission_feeder.sh` and `scripts/run_audit_day_session.sh`).

## Related

- [operations/SCHEDULED_AUDIT_MISSIONS.md](operations/SCHEDULED_AUDIT_MISSIONS.md)
- [OPERATOR_CONSOLE.md](OPERATOR_CONSOLE.md)
- [AGENT_RUNS_OVERSIGHT.md](AGENT_RUNS_OVERSIGHT.md)
