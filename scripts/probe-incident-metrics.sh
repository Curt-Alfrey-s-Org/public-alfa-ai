#!/usr/bin/env bash
set -euo pipefail
BEARER_FILE=/home/operator/monitoring/prometheus/secrets/alfa_ai_admin_bearer
TOKEN=$(tr -d '\n\r' < "$BEARER_FILE")
echo "bearer bytes: $(wc -c < "$BEARER_FILE")"
curl -sS --max-time 15 -o /tmp/metrics.out -w "HTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  http://hub/alfa-ai/api/admin/metrics/prometheus
head -3 /tmp/metrics.out 2>/dev/null || true
