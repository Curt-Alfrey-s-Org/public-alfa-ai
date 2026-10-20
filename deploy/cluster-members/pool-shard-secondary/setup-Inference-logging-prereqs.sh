#!/usr/bin/env bash
# gpu-248: one-time prereqs for inference error recorder (Start-Stop-AlfaAi.ps1).
#
# Orchestrator SSH uses sudo -n to launch systemd-run recorders that survive session end.
# Run once on secondary after bootstrap:
#   sudo bash deploy/cluster-members/pool-shard-secondary/setup-inference-logging-prereqs.sh
#
# Verify as operator:
#   sudo -n true && echo sudo_ok
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root (sudo bash $0)" >&2
  exit 1
fi

DEPLOY_USER="${SUDO_USER:-operator}"
REPO="/home/${DEPLOY_USER}/alfa-ai"
COMMON="${REPO}/deploy/cluster-members/_common"

if [[ ! -f "${COMMON}/start-inference-log-session.sh" ]]; then
  echo "ERROR: missing ${COMMON}/start-inference-log-session.sh (git pull or SCP deploy scripts first)" >&2
  exit 1
fi

SUDOERS="/etc/sudoers.d/alfa-ai-inference-${DEPLOY_USER}"
cat >"$SUDOERS" <<EOF
# ALFa inference error recorder (Start-Stop-AlfaAi.ps1 from orchestrator)
Defaults:${DEPLOY_USER} !requiretty
Defaults:${DEPLOY_USER} env_keep += "ALFA_AI_REPO inference_LOG_SESSION_ID HOST_LABEL PATH TEE_LOG SCP_TO_93"
${DEPLOY_USER} ALL=(ALL) NOPASSWD: SETENV: /usr/bin/systemd-run
${DEPLOY_USER} ALL=(ALL) NOPASSWD: SETENV: /bin/bash ${COMMON}/start-inference-log-session.sh
${DEPLOY_USER} ALL=(ALL) NOPASSWD: SETENV: /bin/bash ${COMMON}/stop-inference-log-session.sh
${DEPLOY_USER} ALL=(ALL) NOPASSWD: SETENV: /bin/bash ${COMMON}/record-inference-host-logs.sh
${DEPLOY_USER} ALL=(ALL) NOPASSWD: /bin/systemctl stop inference-recorder-*
EOF
chmod 440 "$SUDOERS"
visudo -cf "$SUDOERS"

if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$DEPLOY_USER" 2>/dev/null || true
fi

mkdir -p "${REPO}/logs/inference-sessions"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${REPO}/logs" 2>/dev/null || true

echo "OK: inference logging prereqs for ${DEPLOY_USER}"
echo "  sudoers: ${SUDOERS}"
echo "  verify:  sudo -u ${DEPLOY_USER} sudo -n true && echo sudo_ok"
