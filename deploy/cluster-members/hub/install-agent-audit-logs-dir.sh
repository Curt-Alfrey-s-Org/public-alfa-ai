#!/usr/bin/env bash
# One-time: create hub directory for agent audit findings (operator-writable).
# Usage (on hub as operator):
#   bash deploy/cluster-members/hub/install-agent-audit-logs-dir.sh
set -euo pipefail

LOG_DIR="${ALFA_AI_AUDIT_LOG_DIR:-/mnt/hub/alfa-ai/agent-audit-logs}"
OWNER="${ALFA_AI_AUDIT_LOG_OWNER:-operator}"
GROUP="${ALFA_AI_AUDIT_LOG_GROUP:-alfa-ai}"

if [[ ! -d "$(dirname "${LOG_DIR}")" ]]; then
  echo "parent missing: $(dirname "${LOG_DIR}")" >&2
  exit 1
fi

if [[ -d "${LOG_DIR}" ]]; then
  echo "exists: ${LOG_DIR}"
else
  sudo mkdir -p "${LOG_DIR}"
  echo "created: ${LOG_DIR}"
fi

if getent group "${GROUP}" >/dev/null 2>&1; then
  sudo chown "${OWNER}:${GROUP}" "${LOG_DIR}"
  sudo chmod 2770 "${LOG_DIR}"
else
  sudo chown "${OWNER}:${OWNER}" "${LOG_DIR}"
  sudo chmod 2775 "${LOG_DIR}"
fi

echo "ok: ${LOG_DIR} owner=$(stat -c '%U:%G' "${LOG_DIR}") mode=$(stat -c '%a' "${LOG_DIR}")"
