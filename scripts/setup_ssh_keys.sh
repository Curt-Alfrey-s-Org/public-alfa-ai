#!/usr/bin/env bash
set -euo pipefail

# Generate a cluster SSH keypair on the cluster hub (inference) or apps host (apps) and print
# instructions for installing it on every member.
# Idempotent: skips key generation if the key already exists.
#
# Usage (run on inference or apps):
#   ./scripts/setup_ssh_keys.sh
#   ./scripts/setup_ssh_keys.sh --test          # only test connectivity, skip keygen
#
# After keygen, copy the printed public key to each member (see instructions).
# Then re-run with --test to verify passwordless access.

KEY_PATH="${HOME}/.ssh/id_ed25519_cluster"
KEY_COMMENT="alfa-ai-cluster@$(hostname)"

# Cluster members: name ip user
# hub: operator is the canonical ops user on this cluster's hub (root SSH
# is disabled). Override hub_SSH_USER only for other installs.
hub_SSH_USER="${hub_SSH_USER:-operator}"
MEMBERS=(
  "hub    hub  ${hub_SSH_USER}"
  "win93      orchestrator   operator"
  "gaming-worker-b249   orchestrator  operator"
  "GamingWorkerC  orchestrator   operator"
  "gaming-worker-a  orchestrator  Corey"
)

TEST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --test) TEST_ONLY=1 ;;
    -h|--help)
      sed -n '1,20p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ "$TEST_ONLY" -eq 0 ]]; then
  if [[ -f "$KEY_PATH" ]]; then
    echo "Key already exists: $KEY_PATH"
  else
    echo "Generating ed25519 keypair..."
    mkdir -p "$(dirname "$KEY_PATH")"
    ssh-keygen -t ed25519 -C "$KEY_COMMENT" -f "$KEY_PATH" -N ""
    echo "Key generated: $KEY_PATH"
  fi

  PUBKEY_FILE="${KEY_PATH}.pub"
  PUBKEY="$(cat "$PUBKEY_FILE")"
  echo ""
  echo "=========================================="
  echo "  PUBLIC KEY (single line -- also in file)"
  echo "=========================================="
  echo ""
  echo "$PUBKEY"
  echo ""
  echo "Authoritative one-line file (use this path; avoids terminal line-wrap):"
  echo "  $PUBKEY_FILE"
  echo ""

  echo "--- Easiest: from inference, install on hub (password once) ---"
  echo ""
  echo "  ssh-copy-id -i \"$PUBKEY_FILE\" -o StrictHostKeyChecking=accept-new ${hub_SSH_USER}@hub"
  echo ""
  echo "If you see: mkdir: cannot create directory '.ssh': Operation not permitted"
  echo "  hub often uses a non-writable home (e.g. /var/empty) for SSH users. ssh-copy-id"
  echo "  cannot create ~/.ssh. Use ONE of these instead:"
  echo ""
  echo "  A) Web UI (recommended): Credentials -> Users -> ${hub_SSH_USER} -> Edit."
  echo "     Paste the ONE line from $PUBKEY_FILE into Authorized Keys (or SSH Public Key), Save."
  echo ""
  echo "  A2) hub Shell as root (same effect as UI). Paste your one-line key into PUBKEY:"
  echo ""
  sed "s/@USER@/${hub_SSH_USER}/g" <<'EOS'
    PUBKEY='ssh-ed25519 AAAA...paste-full-line-here...'
    midclt call user.update "$(midclt call user.query '[["username","=","@USER@"]]' | jq -r '.[0].id')" "$(jq -n --arg k "$PUBKEY" '{sshpubkey: $k}')"
EOS
  echo ""
  echo "  If midclt says: Home directory is not writable, leave this blank"
  echo "    hub will not store an SSH key until the user has a writable home on a pool."
  echo "    On this cluster, use the HDDS pool: Storage -> create dataset e.g. HDDs/homes (if missing),"
  echo "    then Credentials -> Users -> ${hub_SSH_USER} -> Edit -> Home directory:"
  echo "      /mnt/HDDs/homes/${hub_SSH_USER}"
  echo "    Save, then retry midclt or paste the key in the UI."
  echo ""
  echo "  B) (Skipped) Root SSH is disabled on hub -- use ${hub_SSH_USER} for all access."
  echo ""
  echo "  C) from inference, show the line to paste:  cat \"$PUBKEY_FILE\""
  echo ""

  echo "--- Linux / hub (manual: run ON the member) ---"
  echo ""
  echo "  mkdir -p ~/.ssh && chmod 700 ~/.ssh"
  echo "  cat >> ~/.ssh/authorized_keys   # paste the ONE line from $PUBKEY_FILE, then Ctrl-D"
  echo "  chmod 600 ~/.ssh/authorized_keys"
  echo ""
  echo "  Pipe from inference (password once):"
  echo "    cat \"$PUBKEY_FILE\" | ssh -o StrictHostKeyChecking=accept-new ${hub_SSH_USER}@hub \\"
  echo "      'umask 077; mkdir -p .ssh; cat >> .ssh/authorized_keys'"
  echo ""

  echo "--- hub (hub) key-only from inference ---"
  echo ""
  echo "  1. Enable SSH on hub (System Settings -> SSH) if not already."
  echo "  2. Install the key (ssh-copy-id or UI per section above)."
  echo "  3. On apps, append this block to ~/.ssh/config so ssh/scp/rsync use the cluster key:"
  echo ""
  cat <<EOF
Host hub hub
    HostName hub
    User ${hub_SSH_USER}
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
  echo ""
  echo "  4. Test (must print ok, no password prompt):"
  echo "       ssh -o BatchMode=yes hub 'echo ok'"
  echo ""

  echo "--- Windows (run ON the member in PowerShell as Admin) ---"
  echo ""
  echo "  Copy the ONE line from $PUBKEY_FILE on apps (scp, USB, or paste from terminal)."
  echo '  $authorizedKeys = "$env:USERPROFILE\.ssh\authorized_keys"'
  echo '  if (-not (Test-Path "$env:USERPROFILE\.ssh")) { New-Item -ItemType Directory -Path "$env:USERPROFILE\.ssh" | Out-Null }'
  echo '  Add-Content -Path $authorizedKeys -Value "<paste-the-single-line-pubkey-here>"'
  echo ""
  echo "  # If running OpenSSH server, also add to administrators_authorized_keys (same line)."
  echo '  icacls $env:ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"'
  echo ""
fi

if [[ "$TEST_ONLY" -eq 1 ]] && [[ ! -f "$KEY_PATH" ]]; then
  echo "ERROR: No key at $KEY_PATH. Run without --test first." >&2
  exit 1
fi

echo "--- Connectivity test (BatchMode -- no password prompts) ---"
echo ""
PASS=0
FAIL=0
for entry in "${MEMBERS[@]}"; do
  read -r name ip user <<< "$entry"
  printf "  %-14s %s@%-16s " "$name" "$user" "$ip"
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       -i "$KEY_PATH" "${user}@${ip}" "echo ok" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed out of ${#MEMBERS[@]} members."
[[ "$FAIL" -gt 0 ]] && echo "Install the public key on failed hosts, then re-run: $0 --test"
exit 0
