#!/usr/bin/env bash
# One-time: passwordless sudo for operator on Pi4 (matches VM110 /etc/sudoers.d/90-operator).
#
# Run on the Pi (console) or from orchestrator with a TTY (password prompt once):
#   ssh -t pi4 "bash -s" < deploy/cluster-members/solar-broker/install-passwordless-sudo.sh
#
# Official: visudo -c validates before relying on the fragment (sudoers(5), visudo(8)).
set -euo pipefail

FRAG="/etc/sudoers.d/90-operator"
LINE="operator ALL=(ALL) NOPASSWD:ALL"

if [[ "$(id -un)" != "operator" ]]; then
  echo "ERROR: run as operator (got $(id -un))" >&2
  exit 1
fi

if [[ -f "$FRAG" ]] && grep -qF "$LINE" "$FRAG" 2>/dev/null; then
  echo "OK: $FRAG already contains NOPASSWD rule"
  sudo -n true
  echo "sudo -n: OK"
  exit 0
fi

echo "$LINE" | sudo tee "$FRAG" >/dev/null
sudo chmod 440 "$FRAG"
sudo visudo -c
sudo -n true
echo "OK: passwordless sudo enabled for operator"
