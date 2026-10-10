#!/usr/bin/env bash
# Daytime (or overnight) read-only audit session: feeder + findings export loop.
# Start once; stop with: touch ${LOG_DIR}/STOP or kill the nohup PID.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALFA_AI_ENV_FILE="${ALFA_AI_ENV_FILE:-${REPO_ROOT}/deploy/.env}"
LOG_DIR="${ALFA_AI_AUDIT_LOG_DIR:-/mnt/hub/alfa-ai/agent-audit-logs}"
FEED_INTERVAL_SEC="${ALFA_AI_AUDIT_FEED_INTERVAL_SEC:-2700}"
EXPORT_INTERVAL_SEC="${ALFA_AI_AUDIT_EXPORT_INTERVAL_SEC:-600}"
FEEDER_PAUSE_FILE="${LOG_DIR}/FEEDER_PAUSE"

export ALFA_AI_ENV_FILE
export ALFA_AI_AUDIT_LOG_DIR="${LOG_DIR}"
export ALFA_API="${ALFA_API:-http://127.0.0.1:8420}"

mkdir -p "${LOG_DIR}"
SESSION_LOG="${LOG_DIR}/session.log"
STOP_FILE="${LOG_DIR}/STOP"

if [[ -f "${STOP_FILE}" ]]; then
  rm -f "${STOP_FILE}"
fi

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "${SESSION_LOG}"
}

log "audit day session start feed=${FEED_INTERVAL_SEC}s export=${EXPORT_INTERVAL_SEC}s log_dir=${LOG_DIR}"

last_feed=0
last_export=0
now_epoch() { date +%s; }

while [[ ! -f "${STOP_FILE}" ]]; do
  now="$(now_epoch)"

  if (( now - last_export >= EXPORT_INTERVAL_SEC )); then
    if python3 "${REPO_ROOT}/scripts/export_audit_findings.py" --env-file "${ALFA_AI_ENV_FILE}" >> "${SESSION_LOG}" 2>&1; then
      log "export pass ok"
      if python3 "${REPO_ROOT}/scripts/judge_audit_findings.py" --env-file "${ALFA_AI_ENV_FILE}" >> "${SESSION_LOG}" 2>&1; then
        log "judge pass ok"
      else
        log "judge pass failed (see session.log)"
      fi
    else
      log "export pass failed (see session.log)"
    fi
    last_export="${now}"
  fi

  if (( now - last_feed >= FEED_INTERVAL_SEC )); then
    if [[ -f "${FEEDER_PAUSE_FILE}" ]]; then
      log "feeder pass skipped (FEEDER_PAUSE)"
    elif bash "${REPO_ROOT}/scripts/audit_mission_feeder.sh" >> "${SESSION_LOG}" 2>&1; then
      log "feeder pass ok"
    else
      log "feeder pass failed (see session.log)"
    fi
    last_feed="${now}"
  fi

  sleep 30

  python3 -c "import sys; sys.path.insert(0, '${REPO_ROOT}'); from pathlib import Path; from src.ops.mission_heartbeat import write_heartbeat; write_heartbeat(Path('${LOG_DIR}'), 'day-session', status='alive', last_action='loop tick feed=${FEED_INTERVAL_SEC}s export=${EXPORT_INTERVAL_SEC}s')" 2>/dev/null || true
done

log "audit day session stopped (STOP file)"
rm -f "${STOP_FILE}"
