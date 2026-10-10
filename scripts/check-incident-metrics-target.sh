#!/usr/bin/env bash
set -euo pipefail
BEARER_FILE="${BEARER_FILE:-/home/operator/monitoring/prometheus/secrets/alfa_ai_admin_bearer}"
BRAIN_URL="${BRAIN_URL:-http://hub}"

echo "=== bearer file ==="
stat -c 'mtime=%y bytes=%s' "$BEARER_FILE" 2>/dev/null || echo "missing"

echo "=== prometheus target ==="
python3 <<'PY'
import json, urllib.request
d = json.load(urllib.request.urlopen("http://127.0.0.1:9092/api/v1/targets"))
for t in d["data"]["activeTargets"]:
    if t["labels"].get("job") == "alfa-ai-incident-metrics":
        print("health:", t["health"])
        print("lastError:", t.get("lastError", ""))
        break
else:
    print("job not found")
PY

echo "=== direct metrics probe ==="
TOKEN=$(tr -d '\n\r' < "$BEARER_FILE")
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
  "$BRAIN_URL/alfa-ai/api/admin/metrics/prometheus")
echo "HTTP: $CODE"
