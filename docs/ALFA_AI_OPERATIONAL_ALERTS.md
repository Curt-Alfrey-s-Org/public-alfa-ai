# Operational alerts (admin UI + Prometheus)

Operators should not have to discover JWT scrape failures or ephemeral brain secrets by
hunting logs. ALFa surfaces these as **admin popups**, **Health page warnings**, and
**Prometheus alerts** that flow into the Monitoring tab via Alertmanager.

## What is monitored

| ID | Severity | Detection | Operator impact |
|----|----------|-----------|-----------------|
| `jwt_secret_ephemeral` | **error** | `ALFA_AI_JWT_SECRET` unset in brain `deploy/.env` | Every `alfa-ai-api` recreate invalidates admin JWTs and the Prometheus bearer on `monitor` |
| `prometheus_incident_metrics_down` | **error** | Brain polls `monitor` Prometheus targets API (`ALFA_AI_PROMETHEUS_URL`) for job `alfa-ai-incident-metrics` | Incident SLO metrics missing; often stale bearer after JWT rotation |

## Admin UI

| Surface | Behavior |
|---------|----------|
| **All admin tabs** | `OperationalAlertsBanner` polls `GET /alfa-ai/api/admin/operational-warnings` every 30s. **Error** items open a modal on first sight; all items show a banner under the admin header until dismissed for the browser session. |
| **Health tab** | Same warnings appear in `operational_warnings` on `GET /alfa-ai/api/admin/health`. |

Dismissal is per-warning per browser session (`sessionStorage`). New warnings or changed
fingerprints re-open the modal.

## API

`GET /alfa-ai/api/admin/operational-warnings` — admin JWT only.

Response:

```json
{
  "warnings": [
    {
      "id": "jwt_secret_ephemeral",
      "level": "error",
      "title": "JWT secret not configured",
      "message": "...",
      "hint": "..."
    }
  ],
  "ts": 1710000000
}
```

## Prometheus metrics (admin scrape)

| Metric | Meaning |
|--------|---------|
| `alfa_ai_jwt_secret_ephemeral` | `1` when `ALFA_AI_JWT_SECRET` is unset |

## Prometheus alert rules (monitoring repo on `monitor`)

Copy [deploy/prometheus-rules/alfa-ai-operational.yml](../deploy/prometheus-rules/alfa-ai-operational.yml)
into the monitoring repo `prometheus/rules/` and reload Prometheus. Alerts route through
existing Alertmanager → `POST /alfa-ai/api/internal/alerts` (see [MONITORING_AI_REVIEW.md](MONITORING_AI_REVIEW.md)).

| Alert | Expr (summary) |
|-------|----------------|
| `AlfaAiJwtSecretEphemeral` | `alfa_ai_jwt_secret_ephemeral == 1` for 5m |
| `AlfaAiIncidentMetricsScrapeDown` | `up{job="alfa-ai-incident-metrics"} == 0` for **30m**, `keep_firing_for: 30m` (anti-flap) |

### Bearer refresh (monitoring `monitor`) -- anti-flap

Admin access tokens last **5h** (`ACCESS_TOKEN_MINUTES=300`). Two mechanisms keep
the scrape bearer valid:

1. **Cron on `monitor` every 2h** -- `scripts/refresh-alfa-ai-prometheus-bearer.sh`
   (margin under 5h TTL). Cron **skips** when brain `:8420` is down (keeps the
   old bearer; do not clobber).
2. **Cluster start / brain recreate** -- after brain `:8420/health` is green, the
   `orchestrator` orchestrator SSHs to `monitor` (`id_ed25519_93_107`) and runs the same
   script once. That closes the gap when the cluster was stopped longer than the
   token TTL. Ad-hoc `brain_redeploy_api.sh` on `hub` attempts the same SSH; if
   `hub` has no key to `monitor`, cluster start still covers the next full cycle.

| Item | Policy |
|------|--------|
| Script | `scripts/refresh-alfa-ai-prometheus-bearer.sh` (mirrored in monitoring repo) |
| Cron | every **2h** (margin under 5h token TTL) |
| After cluster start | Orchestrator `orchestrator` -> `monitor`; WARN if `monitor` unreachable -- do not fail the pool |
| Prometheus restart | **Forbidden** after bearer update -- `authorization.credentials_file` is read on each scrape ([Prometheus `<http_config>`](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#http_config); [prometheus/common FileSecret.Fetch](https://github.com/prometheus/common/blob/main/config/http_config.go)) |
| Brain down | Script **exits** after health preflight; keeps the existing bearer (do not clobber) |

Failed refreshes while `:8420` is down were the main cause of **FIRING/RESOLVED email
flaps** on `AlfaAiIncidentMetricsScrapeDown` / `TargetDown` for that job.

### After brain redeploy (`hub` API recreate)

Every `brain_redeploy_api.sh` / `brain_redeploy_missions.sh` that recreates
`alfa-ai-api` invalidates the cached admin JWT used by Prometheus on `monitor`.
The script attempts `ssh operator@monitor` to run the refresh (no Prometheus
restart). If that SSH is not configured on `hub`, **cluster start from `orchestrator`**
runs the same refresh after post-start brain health. Confirm on `monitor`:
Prometheus targets UI shows `alfa-ai-incident-metrics` **up**.

### Recovery when refresh returns 401 (dead refresh token)

**Symptom (admin UI):** modal / Health warning
`prometheus_incident_metrics_down` -- Job `alfa-ai-incident-metrics` on `monitor` is
down (**HTTP 401 Unauthorized**). Hint may say refresh bearer from refresh token.

**Cause:** access token expired **and** `alfa_ai_refresh_token` is invalid
(JWT secret rotated, long outage while cron skipped refresh and then clobbered
nothing, password/session churn, or refresh never re-saved after a brain recreate).
Cron alone cannot heal this -- `POST /alfa-ai/api/auth/refresh` also returns 401.

**Steady-state prerequisites (permanent fix):**

1. **Stable** `ALFA_AI_JWT_SECRET` in brain `deploy/.env` on `hub` (64-char hex from
   `openssl rand -hex 32`). Verify without printing the secret:
   - File length: `awk -F= '/^ALFA_AI_JWT_SECRET=/{print length($2)}' deploy/.env`
   - Container: `sudo docker exec alfa-ai-api python -c "import os; print('ok' if os.getenv('ALFA_AI_JWT_SECRET','').strip() else 'UNSET')"`
2. Cron on `monitor` every **2h** running `scripts/refresh-alfa-ai-prometheus-bearer.sh`
   (example: `0 */2 * * * ... >> /tmp/alfa-bearer-refresh.log`).
3. Valid `prometheus/secrets/alfa_ai_refresh_token` (mode `600`, owner `operator`).
4. **Cluster start** refreshes the bearer after brain health (see Bearer refresh above).
   Do not rely on waiting for the next 2h cron after a long stop.

**Unblock scrape (one of these):**

| Path | When | Action |
|------|------|--------|
| A. Browser login | You know the admin password | Log in at `:8420/alfa-ai/login`, then re-save **both** tokens into `monitor` secrets (access -> `alfa_ai_admin_bearer`, refresh -> `alfa_ai_refresh_token`), then run the refresh script once |
| B. Mint inside API | Password unknown / reset but login 401 | On `hub`, mint JWTs for the primary admin uid inside `alfa-ai-api` (`create_access_token` / `create_refresh_token` from `src.api.deps` with `PYTHONPATH=/app`), write them to `monitor` secrets, then run the refresh script. Do **not** restart Prometheus |

**Verify (no restart):**

```bash
# From monitor -- metrics endpoint with current bearer must be 200
bash scripts/refresh-alfa-ai-prometheus-bearer.sh
# Prometheus targets API (wait one scrape_interval ~10s if needed)
curl -fsS http://127.0.0.1:9092/api/v1/targets | python3 -c '
import json,sys
d=json.load(sys.stdin)
for t in d.get("data",{}).get("activeTargets",[]):
  if t.get("labels",{}).get("job")=="alfa-ai-incident-metrics":
    print(t.get("health"), t.get("lastError") or "")
    break
'
```

Expect `up` and empty `lastError`. Admin UI warning clears within ~30s on the next
`operational-warnings` poll (or dismiss for the browser session).

**Incident note (2026-08-04):** after admin password reset + cluster start, cron log
showed refresh **401** while JWT secret was already set (length 64). Minting fresh
access + refresh tokens into `monitor` secrets and running the refresh script restored
`direct_metrics_http=200` and target `health=up` without restarting Prometheus.

## Environment (brain `deploy/.env`)

| Variable | Purpose |
|----------|---------|
| `ALFA_AI_JWT_SECRET` | **Required in production.** Stable HS256 signing key (`openssl rand -hex 32`). |
| `ALFA_AI_PROMETHEUS_URL` | Optional. Default `http://monitor` -- brain polls `/api/v1/targets` for scrape health. |

After setting `ALFA_AI_JWT_SECRET`, recreate `alfa-ai-api`, log in once on `hub:8420`,
refresh the Prometheus bearer on `monitor` (see [SLO_AND_ERROR_BUDGET.md](SLO_AND_ERROR_BUDGET.md)),
and confirm `alfa-ai-incident-metrics` target is **up**.

### Troubleshooting: `.env` has the secret but Health still warns

`alfa-ai-api` loads `deploy/.env` via compose **`env_file`**. Do **not** duplicate
`ALFA_AI_JWT_SECRET` in the compose **`environment:`** block with `${VAR:-}` — an empty
substitute overrides `env_file` and the container sees `UNSET` even when the file is set.

Verify inside the running container (no secret printed):

```bash
sudo docker exec alfa-ai-api python -c "import os; print('ok' if os.getenv('ALFA_AI_JWT_SECRET','').strip() else 'UNSET')"
```

**Note:** `grep ALFA_AI_JWT_SECRET=... | sed 's/=.*/=***/'` shows `***` even when the
value is **empty**. Check length without printing the secret:

```bash
awk -F= '/^ALFA_AI_JWT_SECRET=/{print length($2)}' deploy/.env
```

If `0`, generate with `openssl rand -hex 32` and set in `deploy/.env` before recreate.
`scripts/brain_redeploy_api.sh` fails early when the value is missing or shorter than 16 chars.

If `UNSET` in container but length is non-zero, recreate the API after pulling the latest
compose/scripts (exports JWT from `.env` before `docker compose up`).

## Related

- [ADMIN_HEALTH_WEB_WORKFLOW.md](ADMIN_HEALTH_WEB_WORKFLOW.md)
- [SLO_AND_ERROR_BUDGET.md](SLO_AND_ERROR_BUDGET.md)
- [MONITORING_AI_REVIEW.md](MONITORING_AI_REVIEW.md)
