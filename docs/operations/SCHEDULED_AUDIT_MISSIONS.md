# Scheduled read-only audit missions (learning-loop L0)

Operator runbook for rotating **read-only** agent audits across host repos.
**No automatic public scraping.** Mutate stays off unless you explicitly enable it for a separate implement mission.

SSoT: [.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md).

## Prerequisites

1. inference / `frontier-code` healthy ([GREV27_27B_OPERATOR.md](../GREV27_27B_OPERATOR.md)).
2. Brain API on `hub` with `ALFA_AI_API_TOKEN` set.
3. **Agent worker repo mount (mandatory for audit-repo):** hub clone bind-mounted at `/workspace/alfa-ai:ro` and `ALFA_AI_AUDIT_ROOTS=alfa-ai=/workspace/alfa-ai` in brain `deploy/.env` (see `deploy/docker-compose.yml` `alfa-ai-worker` service). Without this, missions search an empty workspace.
4. Optional extra repos: `ALFA_AI_AUDIT_ROOTS=alfa-ai=/workspace/alfa-ai,contracts-bot=/path,...`
5. `agent-worker` profile **or** manual `POST /api/runs/process-next`.

## Rotation (suggested)

| Night | Goal / skill |
|-------|----------------|
| Mon | `skill=audit-repo` — alfa-ai deploy/ and security surfaces |
| Tue | `skill=audit-repo` — contracts-bot (if in AUDIT_ROOTS) |
| Wed | `skill=error-cataloger` — roll up mission/incident errors |
| Thu | `skill=corrective-analyst` — propose actions from catalog |
| Fri | `skill=audit-repo` — rankings-bot or other consumer |
| Sat | Optional best-practice research (`research_only: true` + SearXNG if enabled) |
| Sun | Eval smoke offline: `python scripts/eval/smoke_runner.py --self-check` |
| Daily 03:30 | **sleep-curator** (Tier A) — [SLEEP_CURATOR_NIGHTLY.md](SLEEP_CURATOR_NIGHTLY.md) |

## Multi-host agent fleet

Per-host `alfa-ai-worker` containers with **host affinity** (`target_host` on
`POST /api/runs`). See [MULTI_HOST_AGENT_FLEET.md](../MULTI_HOST_AGENT_FLEET.md).

Feeder rotation enqueues missions for `hub`, `apps`, `market`, etc. Gaming hosts
`gaming-c`/`gaming-a`/`gaming-b` have stub compose in `deploy/cluster-members/*/AGENT_WORKER.md`
(default off).

## Create a mission

```bash
# From a host that can reach brain operator API (example)
export ALFA_TOKEN='…'   # ALFA_AI_API_TOKEN
export ALFA_API='http://hub'

curl -sS -X POST "$ALFA_API/api/runs" \
  -H "Authorization: Bearer $ALFA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"goal":"Audit deploy/ for secret leakage and compose drift","skill":"audit-repo","research_only":true,"target_host":"111"}'
```

Drain queue (if no agent-worker):

```bash
curl -sS -X POST "$ALFA_API/api/runs/process-next" \
  -H "Authorization: Bearer $ALFA_TOKEN"
```

Repeat process-next until `{"ok":false,"message":"No task available"}`.

## Error catalog + corrective actions

```bash
curl -sS -X POST "$ALFA_API/api/runs" \
  -H "Authorization: Bearer $ALFA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"goal":"Catalog recent failures","skill":"error-cataloger"}'

curl -sS -X POST "$ALFA_API/api/runs" \
  -H "Authorization: Bearer $ALFA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"goal":"Propose corrective actions from catalog","skill":"corrective-analyst"}'
```

Artifacts: under workspace `.alfa_ai/artifacts/{run_id}/{task_id}/`.  
Catalog file: `$ALFA_AI_DATA/errors.jsonl` (default `.alfa_ai/errors.jsonl`).

## Review API (consumers)

```bash
curl -sS -X POST "$ALFA_API/api/agent/review" \
  -H "Authorization: Bearer $ALFA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"repo":"alfa-ai","goal":"Security review of auth paths","focus":"security","max_issues":20}'
```

## Cron (operator-owned; example)

On `hub` (or a jump host), use **your** crontab — do not enable unattended scrape.

### All-day test (feeder + export + judge loop)

Keeps `alfa-ai-worker` busy, exports findings to hub logs, dual-checks with an
independent judge (when enabled), and writes a Cursor handoff for operator review.

**Trust stack:** 27B audit → export → judge on `gaming-c` (not inference) → Cursor paste → you decide.

| File | Purpose |
|------|---------|
| `scripts/run_audit_day_session.sh` | Loop: feeder + export + judge |
| `scripts/audit_mission_feeder.sh` | One enqueue from rotation if active runs &lt; max |
| `scripts/export_audit_findings.py` | Append `findings-YYYY-MM-DD.md` + `findings.jsonl` |
| `scripts/judge_audit_findings.py` | Judge each finding; `judged.jsonl` + `cursor-review-*.md` |

**Log directory (default):** `/mnt/HDDs/Alfa-AI/agent-audit-logs/`

| Output | Purpose |
|--------|---------|
| `findings-YYYY-MM-DD.md` | Raw 27B audit exports (`### Finding N - Severity:` blocks) |
| `judged-findings-YYYY-MM-DD.md` | Per-finding judge verdicts |
| `judged.jsonl` | Machine-readable judged records |
| `cursor-review-YYYY-MM-DD.md` | **Paste into Cursor** for second review |

**Admin UI:** Missions tab **Findings** inbox lists issues by severity with
`would_take_action` (Suggestion / gap proposal). Nothing auto-fixes
([ADMIN_MISSIONS.md](../ADMIN_MISSIONS.md)).

Judge uses existing `ALFA_AI_JUDGE_*` env ([JUDGE_INSTALL_59.md](JUDGE_INSTALL_59.md)).
Default **off** (`ALFA_AI_JUDGE_ENABLED=0`). With judge off, `cursor-review-*.md` still
lists raw findings (judge marked skipped). Nothing auto-fixes.

On `hub`, `operator` cannot `mkdir` new folders directly under the hub root
(permission denied). Use the one-time installer (same pattern as postgres
backup dir in `deploy/cluster-members/hub/deploy.sh`):

```bash
# From hub (operator) after git pull
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash deploy/cluster-members/hub/install-agent-audit-logs-dir.sh
chmod +x scripts/audit_mission_feeder.sh scripts/run_audit_day_session.sh scripts/judge_audit_findings.py
nohup bash scripts/run_audit_day_session.sh >> /mnt/HDDs/Alfa-AI/agent-audit-logs/nohup.log 2>&1 &
echo $! > /mnt/HDDs/Alfa-AI/agent-audit-logs/session.pid

# Stop later:
# touch /mnt/HDDs/Alfa-AI/agent-audit-logs/STOP
```

**Review findings later:**

```bash
less /mnt/HDDs/Alfa-AI/agent-audit-logs/cursor-review-$(date +%Y-%m-%d).md
less /mnt/HDDs/Alfa-AI/agent-audit-logs/judged-findings-$(date +%Y-%m-%d).md
tail -f /mnt/HDDs/Alfa-AI/agent-audit-logs/session.log
```

**Enable judge (after OP-LL-1 on `gaming-c`):** set in `deploy/.env`, recreate `alfa-ai-api`,
ensure day-session host can reach `gaming-c:11434`:

```env
ALFA_AI_JUDGE_ENABLED=1
ALFA_AI_JUDGE_API_BASE=http://orchestrator/v1
ALFA_AI_JUDGE_API_KEY=ollama
ALFA_AI_JUDGE_REMOTE_MODEL=deepseek-r1:14b
```

Worker stays `restart: unless-stopped`; the session script only enqueues, exports, and judges.

### Nightly rotation (after daytime test passes)

```cron
# Export + judge findings every 15 minutes overnight
*/15 2-6 * * * cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && ALFA_AI_ENV_FILE=deploy/.env python3 scripts/export_audit_findings.py >> /mnt/HDDs/Alfa-AI/agent-audit-logs/cron-export.log 2>&1
*/15 2-6 * * * cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && ALFA_AI_ENV_FILE=deploy/.env python3 scripts/judge_audit_findings.py >> /mnt/HDDs/Alfa-AI/agent-audit-logs/cron-judge.log 2>&1

# Enqueue next audit every 45 minutes (02:00-05:45 UTC example)
0,45 2-5 * * * cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && ALFA_AI_ENV_FILE=deploy/.env bash scripts/audit_mission_feeder.sh >> /mnt/HDDs/Alfa-AI/agent-audit-logs/cron-feeder.log 2>&1
```

Or keep `run_audit_day_session.sh` running 24h until you switch to cron.

```cron
# Example: Mon 02:15 UTC read-only audit enqueue (script must exist and use token from root-only file)
# 15 2 * * 1 /usr/local/bin/alfa-enqueue-audit.sh
```

Sample `alfa-enqueue-audit.sh` sketch:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source /root/.config/alfa-ai/audit.env   # ALFA_TOKEN ALFA_API
curl -sS -X POST "$ALFA_API/api/runs" \
  -H "Authorization: Bearer $ALFA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"goal":"Nightly audit-repo rotation","skill":"audit-repo","research_only":true}'
# agent-worker drains; or loop process-next here with a max count
```

## Admin visibility (www Missions tab)

After brain API redeploy with the hub log mount, operators can use **Admin ->
Missions** (admin JWT) for read-only fleet oversight:

- Fleet cards: skill catalog + side-process heartbeats under `heartbeats/`
- Runs list and live SSE tool events (no `ALFA_AI_API_TOKEN` in the browser)
- Hub artifact summary: today's `findings-*.md`, `judged.jsonl`, `cursor-review-*.md`

See [ADMIN_MISSIONS.md](../ADMIN_MISSIONS.md). Create-run / process-next stay on
`:8420/operator/` (LAN token).

## Explicit non-goals

- Auto-merge or auto-approve host actions.
- Nightly public web scraping without allowlist + operator queue.
- Enabling `ALFA_AI_AGENT_MUTATE_ENABLED` for scheduled jobs.

## Related

- [AGENT_RESEARCH_TOOLS.md](../AGENT_RESEARCH_TOOLS.md)
- [AGENT_RUNS_OVERSIGHT.md](../AGENT_RUNS_OVERSIGHT.md)
- [AI_GOVERNANCE.md](../AI_GOVERNANCE.md)
