#!/usr/bin/env bash
# Smoke-test Pool72 online research: SearXNG + web_search from alfa-ai-api.
#
# Usage (From hub as operator):
#   bash scripts/verify-pool72-research-smoke.sh
#   bash scripts/verify-pool72-research-smoke.sh --enqueue-mission
#   bash scripts/verify-pool72-research-smoke.sh --skip-host-curl
#
# --enqueue-mission: POST /api/runs research_only (requires ALFA_AI_API_TOKEN in deploy/.env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ALFA_AI_ENV_FILE:-$REPO_ROOT/deploy/.env}"

DO_HOST_CURL=1
DO_ENQUEUE=0

for arg in "$@"; do
  case "$arg" in
    --skip-host-curl) DO_HOST_CURL=0 ;;
    --enqueue-mission) DO_ENQUEUE=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=/dev/null
source "$SCRIPT_DIR/_alfa_compose_env.sh"

echo "== verify-pool72-research-smoke =="

if [[ "$DO_HOST_CURL" -eq 1 ]]; then
  echo "[1] SearXNG loopback JSON"
  curl -fsS 'http://127.0.0.1:8888/search?q=fastapi+lifespan&format=json' | head -c 300
  echo ""
fi

echo "[2] web_search from alfa-ai-api container"
"${ALFA_AI_DOCKER[@]}" exec alfa-ai-api python -c "
from src.agent.tools import web_search
r = web_search('FastAPI lifespan on_event deprecation official docs')
if not r.get('ok'):
    raise SystemExit('web_search failed: ' + str(r))
n = len(r.get('results') or [])
if n < 1:
    raise SystemExit('web_search returned no results')
print('web_search_ok results=' + str(n))
"

if [[ "$DO_ENQUEUE" -eq 1 ]]; then
  echo "[3] enqueue research_only mission"
  GOAL='Use web_search to find the official FastAPI docs page on lifespan vs on_event; summarize in Sources.'
  "${ALFA_AI_DOCKER[@]}" exec alfa-ai-api python -c "
import json
import os
import httpx

token = (os.getenv('ALFA_AI_API_TOKEN') or '').strip()
if not token:
    raise SystemExit('ALFA_AI_API_TOKEN unset in container')
goal = '''${GOAL}'''
payload = {'goal': goal, 'research_only': True, 'skill': 'audit-repo'}
headers = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
with httpx.Client(timeout=30.0) as client:
    r = client.post('http://127.0.0.1:8000/api/runs', headers=headers, json=payload)
    if r.status_code >= 400:
        body = (r.text or '')[:800]
        raise SystemExit(f'POST /api/runs HTTP {r.status_code}: {body}')
    data = r.json()
print('enqueue_ok run_id=' + str(data.get('run_id')))
"
  echo "Watch Admin -> Missions -> Live tool events for web_search"
  echo "Worker must be up: docker ps --filter name=alfa-ai-worker"
fi

echo "== verify-pool72-research-smoke: ok =="
