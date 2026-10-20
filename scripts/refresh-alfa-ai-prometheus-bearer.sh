#!/usr/bin/env bash
# Refresh alfa_ai_admin_bearer on monitoring monitor from stored refresh token.
# Official auth: POST /alfa-ai/api/auth/refresh (brain on hub:8420).
#
# Prometheus reads authorization.credentials_file on each scrape (secret-from-file
# semantics; see prometheus/prometheus#8551). Do NOT restart Prometheus after a
# bearer update -- restarts create scrape gaps and flapping TargetDown emails.
set -euo pipefail

SECRETS_DIR="${SECRETS_DIR:-/home/operator/monitoring/prometheus/secrets}"
BEARER_FILE="${BEARER_FILE:-$SECRETS_DIR/alfa_ai_admin_bearer}"
REFRESH_FILE="${REFRESH_FILE:-$SECRETS_DIR/alfa_ai_refresh_token}"
BRAIN_URL="${BRAIN_URL:-http://hub}"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

if [[ ! -f "$REFRESH_FILE" ]]; then
  log "ERROR: Missing $REFRESH_FILE -- log in on hub:8420 and save refresh token first."
  exit 1
fi

# Preflight: never wipe a still-valid bearer when the brain is unreachable.
if ! curl -fsS --connect-timeout 5 --max-time 15 "$BRAIN_URL/health" >/dev/null; then
  log "ERROR: brain health check failed at $BRAIN_URL/health -- skip refresh (keep existing bearer)."
  exit 3
fi

REFRESH=$(tr -d '\n\r' < "$REFRESH_FILE")
RESP=$(curl -fsS --connect-timeout 5 --max-time 30 -X POST "$BRAIN_URL/alfa-ai/api/auth/refresh" \
  -H 'Content-Type: application/json' \
  -d "{\"refresh_token\":\"$REFRESH\"}")

ACCESS=$(printf '%s' "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token','') or '')")
if [[ -z "$ACCESS" ]]; then
  log "ERROR: Refresh failed: no access_token (JWT secret may have rotated -- re-login required)."
  exit 2
fi

umask 022
TMP="${BEARER_FILE}.tmp.$$"
printf '%s' "$ACCESS" > "$TMP"
chmod 644 "$TMP"
# operator ownership so cron can refresh without fighting nobody:600 from the container mount.
if chown operator:operator "$TMP" 2>/dev/null; then
  :
fi
mv -f "$TMP" "$BEARER_FILE"
log "Bearer updated (access token len=${#ACCESS}); next Prometheus scrape picks it up (no restart)."

CODE=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 30 \
  -H "Authorization: Bearer $ACCESS" \
  "$BRAIN_URL/alfa-ai/api/admin/metrics/prometheus" || printf '000')
log "metrics endpoint HTTP: $CODE"
if [[ "$CODE" != "200" ]]; then
  log "ERROR: metrics endpoint returned $CODE after refresh"
  exit 4
fi

TARGETS_JSON="$(mktemp)"
if curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:9092/api/v1/targets" -o "$TARGETS_JSON"; then
  python3 - "$TARGETS_JSON" <<'PY'
import json, sys
from pathlib import Path
d = json.loads(Path(sys.argv[1]).read_text())
for t in d.get("data", {}).get("activeTargets", []):
    if t.get("labels", {}).get("job") == "alfa-ai-incident-metrics":
        print(
            "prometheus target health:",
            t.get("health"),
            "lastError:",
            t.get("lastError") or "",
        )
        break
else:
    print("prometheus target: job alfa-ai-incident-metrics not found")
PY
fi
rm -f "$TARGETS_JSON"
