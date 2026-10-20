#!/usr/bin/env bash
set -euo pipefail

# Run ON a cluster member to install a public key for passwordless SSH/SCP access.
# Idempotent: skips if the key is already present.
#
# Usage:
#   bash install_ssh_key.sh "ssh-ed25519 AAAA... comment"
#   bash install_ssh_key.sh < /path/to/pubkey.pub

if [[ $# -ge 1 ]]; then
  PUBKEY="$1"
elif [[ ! -t 0 ]]; then
  PUBKEY="$(cat)"
else
  echo "Usage: $0 <public-key-string>"
  echo "       $0 < /path/to/pubkey.pub"
  exit 1
fi

if [[ -z "$PUBKEY" ]]; then
  echo "ERROR: empty public key" >&2
  exit 1
fi

SSH_DIR="${HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$AUTH_KEYS" ]] && grep -qF "$PUBKEY" "$AUTH_KEYS"; then
  echo "Key already installed in $AUTH_KEYS"
  exit 0
fi

echo "$PUBKEY" >> "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
echo "Key installed in $AUTH_KEYS"
