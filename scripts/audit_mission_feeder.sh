#!/usr/bin/env bash
# Keep the agent-worker queue stocked with read-only audit missions (multi-host).
# Safe to run from cron or run_audit_day_session.sh (operator-owned).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALFA_API="${ALFA_API:-http://127.0.0.1:8420}"
LOG_DIR="${ALFA_AI_AUDIT_LOG_DIR:-/mnt/hub/alfa-ai/agent-audit-logs}"
MAX_ACTIVE="${ALFA_AI_AUDIT_MAX_ACTIVE:-2}"
STATE_FILE="${LOG_DIR}/feeder-rotation.idx"

if [[ -z "${ALFA_TOKEN:-}" ]]; then
  if [[ -n "${ALFA_AI_ENV_FILE:-}" && -f "${ALFA_AI_ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    ALFA_TOKEN="$(grep -E '^ALFA_AI_API_TOKEN=' "${ALFA_AI_ENV_FILE}" | cut -d= -f2- | tr -d '\r')"
  fi
fi
if [[ -z "${ALFA_TOKEN:-}" ]]; then
  echo "Set ALFA_TOKEN or ALFA_AI_ENV_FILE (deploy/.env)" >&2
  exit 2
fi

mkdir -p "${LOG_DIR}"
FEEDER_LOG="${LOG_DIR}/feeder.log"
FEEDER_PAUSE_FILE="${LOG_DIR}/FEEDER_PAUSE"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "${FEEDER_LOG}"
}

if [[ -f "${FEEDER_PAUSE_FILE}" ]]; then
  log "skip enqueue: feeder paused (${FEEDER_PAUSE_FILE})"
  python3 -c "import sys; sys.path.insert(0, '${REPO_ROOT}'); from pathlib import Path; from src.ops.mission_heartbeat import write_heartbeat; write_heartbeat(Path('${LOG_DIR}'), 'day-session-feeder', status='idle', last_action='paused FEEDER_PAUSE')" 2>/dev/null || true
  exit 0
fi

# target_host|goal|skill|research_only (true/false)
ROTATION=(
  "111|Read-only audit alfa-ai deploy/ for secret leakage (alfa-ai/ prefix)|audit-repo|true"
  "111|Read-only audit alfa-ai docs/ for stale runbooks (alfa-ai/ prefix)|audit-repo|true"
  "105|Read-only audit contracts-bot deploy surfaces if mounted|audit-repo|true"
  "102|Read-only audit market-pie5-bot deploy/ if mounted|audit-repo|true"
  "103|Read-only audit atems API auth paths if mounted|audit-repo|true"
  "106|Read-only audit rankings-bot public error strings if mounted|audit-repo|true"
  "107|Read-only audit monitoring alert rules drift if mounted|audit-repo|true"
  "148|Read-only audit alfa-ai edge/RAG deploy if mounted|audit-repo|true"
  "100|Read-only audit alfa-ai pool shard host clone if mounted|audit-repo|true"
  "111|Gather host facts on brain: processes docker disk logs|host-facts|true"
  "105|Gather host facts on apps host: processes docker disk logs|host-facts|true"
  "111|Catalog mission and incident errors from errors.jsonl|error-cataloger|false"
  # Gaming stubs (disabled until operator enables workers on gaming-c/gaming-a/gaming-b):
  # "59|Gather host facts on gaming-worker-c when worker enabled|host-facts|true"
  # "219|Gather host facts on gaming-worker-a when worker enabled|host-facts|true"
  # "249|Gather host facts on gaming-worker-b when worker enabled|host-facts|true"
)

active_count="$(
  python3 - <<'PY' "${ALFA_API}" "${ALFA_TOKEN}"
import json, os, sys, urllib.request
api, token = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"{api}/api/runs",
    headers={"Authorization": f"Bearer {token}"},
)
with urllib.request.urlopen(req, timeout=30) as resp:
    runs = json.load(resp)
active = sum(1 for r in runs if r.get("status") in ("pending", "running"))
print(active)
PY
)"

if [[ "${active_count}" -ge "${MAX_ACTIVE}" ]]; then
  log "skip enqueue: active runs=${active_count} max=${MAX_ACTIVE}"
  python3 -c "import sys; sys.path.insert(0, '${REPO_ROOT}'); from pathlib import Path; from src.ops.mission_heartbeat import write_heartbeat; write_heartbeat(Path('${LOG_DIR}'), 'day-session-feeder', status='idle', last_action='skip enqueue active=${active_count}')" 2>/dev/null || true
  exit 0
fi

idx=0
if [[ -f "${STATE_FILE}" ]]; then
  idx="$(cat "${STATE_FILE}")"
fi
idx=$((idx % ${#ROTATION[@]}))
entry="${ROTATION[$idx]}"
IFS='|' read -r target_host goal skill research_only <<< "${entry}"

payload="$(python3 -c "import json,sys; print(json.dumps({'goal':sys.argv[1],'skill':sys.argv[2],'research_only':sys.argv[3]=='true','target_host':sys.argv[4]}))" \
  "${goal}" "${skill}" "${research_only}" "${target_host}")"

response="$(curl -fsS -X POST "${ALFA_API}/api/runs" \
  -H "Authorization: Bearer ${ALFA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${payload}")"

run_id="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('run_id',''))" "${response}")"
echo $((idx + 1)) > "${STATE_FILE}"
log "enqueued host=${target_host} skill=${skill} run_id=${run_id} active_before=${active_count}"
python3 -c "import sys; sys.path.insert(0, '${REPO_ROOT}'); from pathlib import Path; from src.ops.mission_heartbeat import write_heartbeat; write_heartbeat(Path('${LOG_DIR}'), 'day-session-feeder', status='alive', last_action='enqueued host=${target_host} skill=${skill} run_id=${run_id}')" 2>/dev/null || true
