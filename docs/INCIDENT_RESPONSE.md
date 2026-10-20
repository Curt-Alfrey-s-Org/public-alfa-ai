# Incident response (Alertmanager -> alfa-ai)

Automated cluster alert ingest, investigation, and (optional) allowlisted remediation.

**Plan:** [`.cursor/plans/ALERT_INCIDENT_RESPONSE.md`](../.cursor/plans/ALERT_INCIDENT_RESPONSE.md)

## Flow

1. **monitoring** repo Alertmanager fires an alert (email to operator + webhook to alfa-ai).
2. **alfa-ai-api** `POST /alfa-ai/api/internal/alerts` upserts an incident row (dedupe by fingerprint).
3. Incident ID is pushed to Redis queue `alfaai:queue:incidents`.
4. **alfa-ai-incident-worker** (compose profile `incident-worker`) runs YAML playbooks from `deploy/incident-playbooks/`.
5. Timeline events and status appear at `GET /alfa-ai/api/admin/incidents` (admin JWT).
6. Admin **Monitoring** tab: on-demand AI analysis and optional PR-based remediation ([MONITORING_AI_REVIEW.md](MONITORING_AI_REVIEW.md)).

Monitoring failures never block chat/inference.

## Investigation tools (monitoring repo)

| Need | Where |
|------|-------|
| Metrics, dashboards, alerts | Grafana on **monitor** (monitoring stack on 107 Grafana VM) |
| inference tok/s + per-host GPU | Grafana **inference inference** -- http://monitor/d/inference-inference/inference-inference ([inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md) Live Grafana) |
| Host GPU/CPU temperatures | Grafana **Homelab host temperatures** -- http://monitor/d/homelab-temperatures |
| Load vs temp triage (L1) | Admin **Ask ALFa** chip *"Why is host 111 hot?"* or natural language -- uses `prometheus_ops` snapshot + proposes read-only `docker_stats` / `prom_query` (Approve before SSH) |
| Live container logs (fleet) | Dozzle on **monitor** (central UI + per-host agents) |
| Searchable log history (future) | Grafana Explore -> Loki once remote Alloy agents ship on each host |

Runbook: [monitoring/docs/DOZZLE_FLEET.md](https://github.com/example/monitoring/blob/main/docs/DOZZLE_FLEET.md).

## Enable webhook ingest (brain `hub`) — done 2026-07-07

Phase 0 complete: `ALFA_AI_ALERT_WEBHOOK_TOKEN` set on brain `deploy/.env`; monitoring
`monitor` `email-ops` receiver posts to this endpoint. See [MONITORING_AI_REVIEW.md](MONITORING_AI_REVIEW.md).

**Rotate token:** generate new value, update brain `.env` and monitoring
`secrets/alfa_ai_webhook_token`, recreate `alfa-ai-api`, reload Alertmanager.

Historical first-time steps:

```bash
openssl rand -hex 32
```

Add `ALFA_AI_ALERT_WEBHOOK_TOKEN=<value>` to `deploy/.env` on the brain.

**Step 2 -- From `hub` (operator):** rebuild API and start incident worker:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && git pull --ff-only origin main
```

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && docker compose build alfa-ai-api && docker compose up -d alfa-ai-api
```

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy && docker compose --profile incident-worker up -d alfa-ai-incident-worker
```

## Alertmanager receiver (monitoring repo on `monitor`) — done 2026-07-07

Live config: **`email-ops`** receiver on `monitor` includes email + alfa-ai webhook
(`monitoring` commit `f996cce`). Token file: `secrets/alfa_ai_webhook_token`.

Reference template (for new clones / drift check):

```yaml
receivers:
  - name: alfa-ai-webhook
    webhook_configs:
      - url: http://hub/alfa-ai/api/internal/alerts
        send_resolved: true
        http_config:
          authorization:
            credentials: "<ALFA_AI_ALERT_WEBHOOK_TOKEN>"
```

Alertmanager sends `Authorization: Bearer <token>`. alfa-ai also accepts `X-Alfa-Alert-Token`.

Route critical/warning alerts to `alfa-ai-webhook` plus your email receiver.

## Verify

Synthetic POST from `apps` (replace token):

```bash
curl -fsS -X POST http://hub/alfa-ai/api/internal/alerts -H 'Content-Type: application/json' -H 'X-Alfa-Alert-Token: YOUR_TOKEN' -d '{"status":"firing","receiver":"test","alerts":[{"status":"firing","fingerprint":"test-fp-1","labels":{"alertname":"LiteLLMProbeFailed","severity":"warning"},"annotations":{"summary":"drill"}}]}'
```

Admin UI/API: `GET /alfa-ai/api/admin/incidents` with admin Bearer JWT.

## Playbooks

| File | alertname |
|------|-----------|
| `deploy/incident-playbooks/brain-health-down.yaml` | `AlfaAiBrainHealthDown` |
| `deploy/incident-playbooks/litellm-probe-failed.yaml` | `LiteLLMProbeFailed` |
| `deploy/incident-playbooks/postgres-backup-stale.yaml` | `AlfaAiPostgresBackupStale` |

Alert names must match Prometheus rule `alertname` labels in the monitoring repo.

## Auto-fix

Default **off** (`ALFA_AI_INCIDENT_AUTO_FIX=false`). Even when the global flag is `true`, the worker
runs `auto_fix:` steps **only** for alertnames listed in `ai_settings.auto_fix_allowlist` (or
`ALFA_AI_INCIDENT_AUTO_FIX_ALLOWLIST` env). Empty allowlist = no auto_fix. Playbook `auto_fix`
steps that reference inference/RPC container names are rejected at load time. Worker re-runs investigate
steps to verify before marking `resolved`.

## Email notification

When SMTP is configured, the incident worker emails the operator on `resolved` or `needs_human`. Alertmanager `resolved` webhooks also trigger a "Fixed" email. Direct `[ALFa AI] Serious:` emails use the same SMTP block and are gated by **programmatic** severity routing (`ai_settings` + `ALFA_AI_ALERT_AI_TRIAGE`) -- not an LLM call. See [AI_ACTIONS.md](AI_ACTIONS.md).

| Env var | Purpose |
|---------|---------|
| `ALFA_AI_INCIDENT_SMTP_HOST` | SMTP server |
| `ALFA_AI_INCIDENT_SMTP_PORT` | Default `587` |
| `ALFA_AI_INCIDENT_SMTP_USER` / `PASSWORD` | Auth (optional) |
| `ALFA_AI_INCIDENT_SMTP_FROM` | From header |
| `ALFA_AI_INCIDENT_NOTIFY_EMAIL` | Operator inbox |
| `ALFA_AI_INCIDENT_SMTP_TLS` | Default `true` |

Use the same SMTP credentials as the monitoring stack when possible.

**Parked (2026-09-02):** live `hub` `deploy/.env` does **not** ship a working
incident SMTP block. Missing `[ALFa AI]` / incident-worker mail is expected until
the operator resumes this: reuse the existing Gmail app password from `monitor`
`monitoring/secrets/smtp_password` (do not create a new Google app password),
write `ALFA_AI_INCIDENT_SMTP_*` + `ALFA_AI_INCIDENT_NOTIFY_EMAIL`, then
`bash scripts/brain_redeploy_api.sh --skip-pull`. Prometheus Alertmanager on
`monitor` is a different path and is unaffected.

## Program vs AI (inference slots)

| Path | Mechanism |
|------|-----------|
| Ingest, playbook investigate, auto_fix, severity map, quiet hours, dedup, lifecycle email | **Program code** |
| Admin **Analyze**, **Ask ALFa**, optional unknown-alert summary | **LLM** (on demand / opt-in) |

`ALFA_AI_INCIDENT_LLM_TRIAGE` defaults to **false**. Turn it on only if you want a model summary when no playbook matches.

## Admin UI (Monitoring tab)

https://www.example.com/alfa-ai/admin/incidents (admin JWT required). Tab label is **Monitoring**; route unchanged.

**AI review:** `POST /alfa-ai/api/admin/incidents/{id}/analyze` produces a read-only proposal. **Go ahead** (`POST .../apply` with `{ "confirm": true }`) opens a GitHub PR when `ALFA_AI_REMEDIATION_ENABLED=true`. See [MONITORING_AI_REVIEW.md](MONITORING_AI_REVIEW.md).

## Webhook and incident env vars

| Env var | Purpose |
|---------|---------|
| `ALFA_AI_ALERT_WEBHOOK_TOKEN` | Shared secret for Alertmanager webhook |
| `ALFA_AI_ALERT_ALLOWED_CIDRS` | CIDR allowlist for webhook POST (optional) |
| `ALFA_AI_INCIDENT_QUEUE` | Enqueue incidents for background worker (default `true`) |
| `ALFA_AI_ALERT_AI_TRIAGE` | Programmatic notify routing (default `true`; no LLM) |
| `ALFA_AI_INCIDENT_LLM_TRIAGE` | LLM summary for unknown alerts (default `false`) |
| `ALFA_AI_REMEDIATION_ENABLED` | Allow admin Apply / Go ahead (default `false`) |
| `ALFA_AI_REMEDIATION_GITHUB_TOKEN` | GitHub PAT for PR-based fixes |
| `ALFA_AI_REMEDIATION_ALFA_REPO` | `owner/repo` for alfa-ai |
| `ALFA_AI_REMEDIATION_MONITORING_REPO` | `owner/repo` for monitoring stack |

## Postmortem template

After Sev-1 or prolonged `needs_human` incidents, export a blameless draft from the admin
**Monitoring** tab (**Export postmortem**) or:

`GET /alfa-ai/api/admin/incidents/{id}/postmortem`

The markdown includes timeline events, latest analysis root cause, and placeholders for
impact, action items, and lessons learned. Fill in operator-only sections before sharing.

Sections: Summary, Impact, Timeline, Root cause, What went well/wrong, Action items,
Lessons learned, Runbook link (when `runbook_url` annotation present).

## Monitoring repo template

Copy [docs/monitoring/ALERTMANAGER_ALFA_AI_WEBHOOK.example.yaml](monitoring/ALERTMANAGER_ALFA_AI_WEBHOOK.example.yaml) into the monitoring repo Alertmanager config.

- ROADMAP Phase 4 observability
- [docs/ADMIN_HEALTH_WEB_WORKFLOW.md](ADMIN_HEALTH_WEB_WORKFLOW.md) (passive health UI)
