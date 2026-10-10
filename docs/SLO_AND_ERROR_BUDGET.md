# SLOs and error budgets (ALFa cluster)

**Authority:** Google SRE Book — [Service Level Objectives](https://sre.google/sre-book/service-level-objectives/),
[Embracing Risk](https://sre.google/sre-book/embracing-risk/).  
**Governance:** [AI_GOVERNANCE.md](AI_GOVERNANCE.md).

## Prometheus metrics (alfa-ai admin scrape)

Scrape from the brain API (admin JWT + allowlisted network only):

`GET /alfa-ai/api/admin/metrics/prometheus`

| Metric | Type | Labels | Meaning |
|--------|------|--------|---------|
| `alfa_ai_incidents_open` | Gauge | `status` | Count of incidents in `received`, `investigating`, `needs_human`, `resolved` |
| `alfa_ai_incident_worker_lag_seconds` | Gauge | — | Age of oldest active (`received` or `investigating`) incident |
| `alfa_ai_notifications_total` | Counter | `result` | Programmatic notify path: `sent`, `skipped`, `skipped_smtp` |
| `alfa_ai_autofix_attempts_total` | Counter | `result` | Playbook auto_fix: `verified`, `failed`, `verify_failed`, `rate_limited` |
| `alfa_ai_jwt_secret_ephemeral` | Gauge | — | `1` when `ALFA_AI_JWT_SECRET` is unset (sessions invalidate on API restart) |

Wire these into the monitoring repo on `monitor` after deploy. Add alert rules from
[deploy/prometheus-rules/alfa-ai-operational.yml](../deploy/prometheus-rules/alfa-ai-operational.yml)
(`AlfaAiIncidentMetricsScrapeDown` uses `for: 30m` + `keep_firing_for: 30m` to avoid
bearer-refresh email flaps). See [ALFA_AI_OPERATIONAL_ALERTS.md](ALFA_AI_OPERATIONAL_ALERTS.md)
for admin UI popups, the `monitor` bearer refresh cron plus **cluster-start refresh**
from `orchestrator`, and **recovery when `POST /auth/refresh` returns 401** (dead refresh
token -- mint or re-login, then refresh script; never restart Prometheus).

## Service level indicators (proposed)

| Service | SLI | Target (draft) | Measurement |
|---------|-----|----------------|-------------|
| Brain API | Availability of `/alfa-ai/health` | 99.5% / 30d | Blackbox / brain health |
| LiteLLM | `/health/liveliness` success | 99.5% / 30d | Blackbox `hub:8413` |
| frontier-code | Coordinator `/health` on `:31360` | 99% / 30d (pool fragile) | Probe after full start only |
| Incident worker | `alfa_ai_incident_worker_lag_seconds` p95 | &lt; 300s | Admin Prometheus scrape |
| Alert notify | `alfa_ai_notifications_total{result="sent"}` vs skipped | Best-effort when SMTP configured | Counter + `ai_actions` audit |
| Analyze quality | `proposal_feedback` helpful ratio | Track; no auto-tune from volume alone | `ai_actions` `proposal_feedback` |

## Error budget policy (draft)

- Burn of frontier-code budget → freeze non-essential deploys / speculative features.
- Incident worker failure must **never** take down chat/inference (graceful degrade).
- Do **not** tune `notify_min_severity` from raw email volume alone once budgets exist —
  prefer budget burn + false-positive rate + operator feedback.

## Postmortems

After Sev-1 / prolonged `needs_human` incidents: blameless postmortem using template
in [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md). Export draft from Monitoring tab
(`GET /alfa-ai/api/admin/incidents/{id}/postmortem`).

## Related

- [inference_RPC_RELIABILITY.md](inference_RPC_RELIABILITY.md)
- [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md)
- [MONITORING_AI_REVIEW.md](MONITORING_AI_REVIEW.md)
- Monitoring stack on `monitor` ([REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md))
