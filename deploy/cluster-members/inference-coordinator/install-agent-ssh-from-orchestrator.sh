#!/usr/bin/env bash
# One-time: install orchestrator agent SSH public key for operator on ai-148 (inference).
#
# Run on inference as operator after Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md). on orchestrator:
#   bash ~/alfa-ai/deploy/cluster-members/inference-coordinator/install-agent-ssh-from-93.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUB="${SCRIPT_DIR}/id_ed25519_93_148.pub"
AUTH="${HOME}/.ssh/authorized_keys"

if [[ ! -f "$PUB" ]]; then
  echo "ERROR: missing $PUB (git pull on inference after orchestrator pushed pubkey)" >&2
  exit 1
fi

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
touch "$AUTH"
chmod 600 "$AUTH"

KEY_LINE="$(tr -d '\r\n' <"$PUB")"
if grep -qF "$KEY_LINE" "$AUTH" 2>/dev/null; then
  echo "OK: key already in $AUTH"
else
  echo "$KEY_LINE" >>"$AUTH"
  echo "OK: appended orchestrator agent key to $AUTH"
fi

echo "Verify from orchestrator:"
echo "  ssh -i ~/.ssh/id_ed25519_93_148 operator@orchestrator echo SSH_OK"
