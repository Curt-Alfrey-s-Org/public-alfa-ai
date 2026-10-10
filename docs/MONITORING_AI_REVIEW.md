# Monitoring tab (AI review and remediation)

Admin UI at `/alfa-ai/admin/incidents` (tab label **Monitoring**) lets operators review
Alertmanager incidents from the **monitoring** repo, run on-demand alfa-ai analysis, and
optionally apply fixes after explicit confirmation.

**Related:** [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md), [AI_ACTIONS.md](AI_ACTIONS.md), [monitoring/ALERTMANAGER_ALFA_AI_WEBHOOK.example.yaml](monitoring/ALERTMANAGER_ALFA_AI_WEBHOOK.example.yaml)

> The **Monitoring** tab is operator-driven (you click Analyze / Go ahead). Automatic alert
> **routing** (severity map, threshold, quiet hours, dedup, direct ops email) is **program
> code** in the incident worker -- see the **AI Actions** tab ([AI_ACTIONS.md](AI_ACTIONS.md)).
> A floating **Ask ALFa** chat widget (also documented there) is available on this and every
> other admin tab for judgment questions and approval-gated host actions.

## Flow

1. **monitoring** Alertmanager fires -> webhook -> `POST /alfa-ai/api/internal/alerts`.
2. Incident appears in the **Monitoring** admin tab (same Postgres store as background worker).
3. Admin clicks **Analyze with alfa-ai** -> `POST /alfa-ai/api/admin/incidents/{id}/analyze`.
4. alfa-ai returns a **proposal** (classification, root cause, suggested file change or ops steps).
5. Default is **read-only**. Admin reviews the proposal and its **Proposed change (preview)**
   block on the Monitoring tab before applying (see [Proposed change preview](#proposed-change-preview)).
6. Admin clicks **Go ahead** (typed confirm) -> `POST /alfa-ai/api/admin/incidents/{id}/apply`.
7. When remediation is enabled, alfa-ai opens a **GitHub PR** on a feature branch (never commits to `main`).
8. Operator merges PR on the owning host, then `git pull` + deploy per [cluster-sync-order](../.cursor/rules/cluster-sync-order.mdc).

## Guardrails

| Control | Default |
|---------|---------|
| `ALFA_AI_REMEDIATION_ENABLED` | `false` -- Apply button returns 403 until enabled |
| Apply requires `{ "confirm": true }` in POST body | mandatory |
| GitHub apply | feature branch + PR only |
| Admin auth | JWT + `ALFA_AI_ADMIN_ALLOWED_CIDRS` |
| Audit | `incident_remediation_apply` in audit_log |

Background incident worker auto-fix (`ALFA_AI_INCIDENT_AUTO_FIX`) is separate and remains off by default.

## Environment (brain `deploy/.env`)

### Alert webhook ingest

| Variable | Purpose |
|----------|---------|
| `ALFA_AI_ALERT_WEBHOOK_TOKEN` | Shared secret; Alertmanager Bearer / `X-Alfa-Alert-Token` |
| `ALFA_AI_ALERT_ALLOWED_CIDRS` | LAN CIDRs allowed to POST webhook (empty = private ranges) |
| `ALFA_AI_INCIDENT_QUEUE` | Push new incidents to Redis worker queue (default `true`) |

### Outbound incident email

| Variable | Purpose |
|----------|---------|
| `ALFA_AI_INCIDENT_SMTP_HOST` | SMTP server |
| `ALFA_AI_INCIDENT_SMTP_PORT` | Default `587` |
| `ALFA_AI_INCIDENT_SMTP_USER` / `PASSWORD` | Auth (optional) |
| `ALFA_AI_INCIDENT_SMTP_FROM` | From header |
| `ALFA_AI_INCIDENT_NOTIFY_EMAIL` | Operator inbox |
| `ALFA_AI_INCIDENT_SMTP_TLS` | Default `true` |

### AI remediation (PR apply)

| Variable | Purpose |
|----------|---------|
| `ALFA_AI_REMEDIATION_ENABLED` | `true` to allow Go ahead / apply |
| `ALFA_AI_REMEDIATION_GITHUB_TOKEN` | PAT with `repo` scope for target repos |
| `ALFA_AI_REMEDIATION_ALFA_REPO` | e.g. `example/alfa-ai` |
| `ALFA_AI_REMEDIATION_MONITORING_REPO` | e.g. `example/monitoring` |

GitHub REST API: https://docs.github.com/en/rest

## Phase 0: wire monitoring Alertmanager (monitor)

**Status (2026-07-07):** Live on `monitor` — `email-ops` receiver sends email **and** webhook to brain; token in `secrets/alfa_ai_webhook_token` (gitignored) matching brain `ALFA_AI_ALERT_WEBHOOK_TOKEN`.

**Step 1 -- From alfa-ai owning host:** set `ALFA_AI_ALERT_WEBHOOK_TOKEN` in brain `deploy/.env` (see INCIDENT_RESPONSE.md).

**Step 2 -- From `monitor` (monitoring operator):** copy [ALERTMANAGER_ALFA_AI_WEBHOOK.example.yaml](monitoring/ALERTMANAGER_ALFA_AI_WEBHOOK.example.yaml) into the monitoring repo `alertmanager.yml`, replace `REPLACE_WITH_ALFA_AI_ALERT_WEBHOOK_TOKEN`, reload Alertmanager.

**Step 3 -- Smoke test** from any LAN host with the token:

```bash
curl -fsS -X POST http://hub/alfa-ai/api/internal/alerts -H 'Content-Type: application/json' -H 'X-Alfa-Alert-Token: YOUR_TOKEN' -d '{"status":"firing","receiver":"test","alerts":[{"status":"firing","fingerprint":"test-fp-drill","labels":{"alertname":"LiteLLMProbeFailed","severity":"warning"},"annotations":{"summary":"drill"}}]}'
```

**Step 4 -- Verify UI:** open Monitoring tab, select incident, run Analyze.

## Classification types

| Type | Apply behavior |
|------|----------------|
| `alert_tuning` | PR to monitoring repo with updated rule/threshold YAML |
| `code_fix` | PR to alfa-ai (or named repo) with file replacement |
| `ops_action` | Recorded in timeline; no PR (operator runs steps manually) |

## Analysis briefing (Wave 3)

Analyze returns a structured **briefing** alongside the proposal:

- `evidence`, `ranked_causes`, `suggested_actions`, `blast_radius`
- `runbook_links` (from alert annotations + repo docs)
- `copy_for_verifier` (paste into a stronger model for dual-check)

Default classification is `ops_action` when file context is missing or path policy rejects a change.

## Proposed change preview

File proposals (`code_fix`, `alert_tuning`) include `target_repo`, optional `target_path`, and
`proposed_change` from Analyze. The Monitoring tab shows:

- **Heading:** `{target_repo} / {target_path}` when a path is present.
- **Proposed change (preview):** scrollable preview of `proposed_change` before **Go ahead**.
- When the text looks like a unified diff (`---` / `+++` / `@@` headers or many `+`/`-` lines),
  added lines render green and removed lines red; otherwise the full text is shown with
  whitespace preserved.

Review this preview (and the briefing above it) before Apply. Low-confidence proposals still
require the extra **force** checkbox per the table below.

## Confidence gate

| Confidence | Apply without extra confirm |
|------------|----------------------------|
| `high` / `medium` | Yes, with standard Go ahead checkbox |
| `low` | Requires `{ "force": true }` after operator verification |

## Operator feedback (Measure)

Thumbs on proposals: `POST /alfa-ai/api/admin/incidents/{id}/proposals/{proposal_id}/feedback`

Records `proposal_feedback` in `ai_actions` for quality tracking.

## Prometheus metrics

Admin scrape: `GET /alfa-ai/api/admin/metrics/prometheus` — see [SLO_AND_ERROR_BUDGET.md](SLO_AND_ERROR_BUDGET.md).
