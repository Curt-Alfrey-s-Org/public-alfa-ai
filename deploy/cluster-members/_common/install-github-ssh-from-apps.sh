#!/usr/bin/env bash
# Copy operator@105 GitHub SSH identity to this host (operator Ubuntu VMs).
#
# Official GitHub SSH: https://docs.github.com/en/authentication/connecting-to-github-with-ssh
#
# Prerequisite: passwordless scp from this host to operator@apps, OR run
# deploy/cluster-members/orchestrator/Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md). from orchestrator
# (relays the key without apps exposing the private key over LAN to every host).
#
# Run on target VM as operator:
#   bash ~/alfa-ai/deploy/cluster-members/_common/install-github-ssh-from-105.sh
set -euo pipefail

APPS="operator@apps"
SSH_DIR="${HOME}/.ssh"
PRIV="${SSH_DIR}/id_ed25519_github"
PUB="${PRIV}.pub"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

scp -o BatchMode=yes -o ConnectTimeout=20 "${APPS}:.ssh/id_ed25519" "$PRIV"
scp -o BatchMode=yes -o ConnectTimeout=20 "${APPS}:.ssh/id_ed25519.pub" "$PUB"
chmod 600 "$PRIV"
chmod 644 "$PUB"

if [[ ! -f "${SSH_DIR}/config" ]] || ! grep -q '^Host github.com$' "${SSH_DIR}/config" 2>/dev/null; then
  printf '%s\n' \
    'Host github.com' \
    '    HostName github.com' \
    '    User git' \
    '    IdentityFile ~/.ssh/id_ed25519_github' \
    '    IdentitiesOnly yes' \
    '    StrictHostKeyChecking accept-new' >>"${SSH_DIR}/config"
fi
chmod 600 "${SSH_DIR}/config"
ssh-keyscan -H github.com >>"${SSH_DIR}/known_hosts" 2>/dev/null || true
chmod 600 "${SSH_DIR}/known_hosts" 2>/dev/null || true

ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$PRIV" -T operator@example.com 2>&1 | head -1
