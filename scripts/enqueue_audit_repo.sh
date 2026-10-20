#!/usr/bin/env bash
# Enqueue a read-only audit-repo mission on the brain API.
# Usage: ALFA_TOKEN=... bash scripts/enqueue_audit_repo.sh [optional goal text]
set -euo pipefail

ALFA_API="${ALFA_API:-http://127.0.0.1:8420}"
GOAL="${1:-Read-only audit of alfa-ai deploy/ and docs/ (use alfa-ai/ path prefix)}"

if [[ -z "${ALFA_TOKEN:-}" ]]; then
  echo "Set ALFA_TOKEN (brain ALFA_AI_API_TOKEN)" >&2
  exit 2
fi

curl -fsS -X POST "${ALFA_API}/api/runs" \
  -H "Authorization: Bearer ${ALFA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'goal':sys.argv[1],'skill':'audit-repo','research_only':True}))" "$GOAL")"

echo
