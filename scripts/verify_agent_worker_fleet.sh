#!/usr/bin/env bash
# Verify multi-host agent worker fleet heartbeats (run on hub or any host with REDIS_URL).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV="${ALFA_AI_ENV_FILE:-${REPO_ROOT}/deploy/.env}"
if [[ -f "${ENV}" ]]; then
  # shellcheck source=/dev/null
  set -a
  source "${ENV}"
  set +a
fi

python3 <<'PY'
import os
import sys

sys.path.insert(0, os.environ.get("REPO_ROOT", "/mnt/hub/alfa-ai/repo/alfa-ai"))

from src.api.redis_heartbeat import get_worker_heartbeat

hosts = ["111", "105", "102", "103", "106", "107", "148", "100"]
ok = 0
for host in hosts:
    hb = get_worker_heartbeat(f"alfa-ai-worker-{host}")
    if not hb:
        print(f"{host}: MISSING")
        continue
    extra = hb.get("extra") or {}
    print(f"{host}: {extra.get('status', 'alive')} last={extra.get('last_action', '')[:60]}")
    ok += 1
print(f"alive_count={ok}/{len(hosts)}")
PY
