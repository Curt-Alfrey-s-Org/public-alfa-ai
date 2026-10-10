#!/usr/bin/env bash
# TCP post-stop: every host:port in the shard list must NOT accept connections.
# Prefer inference-shards.active.env (core + opted-in gaming) so stop cannot
# declare success while gaming-a/:31352 etc. are still listening.
#
# Win10 WSL NAT exception: netsh portproxy keeps the Windows LAN listen open
# after the WSL rpc-server is gone
# (https://learn.microsoft.com/en-us/windows/wsl/networking).
# Those hosts are skipped here; the orchestrator verifies them via SSH + WSL
# (gaming-stop-for-session.ps1). Override with WIN10_NAT_SKIP_HOSTS.
#
# Usage:
#   bash deploy/cluster-members/_common/verify-inference-stopped.sh
#   bash .../verify-inference-stopped.sh /path/to/inference-shards.active.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
ACTIVE="$REPO_DIR/deploy/llamacpp-rpc/inference-shards.active.env"
CORE="$REPO_DIR/deploy/llamacpp-rpc/inference-shards.env"
if [[ -n "${1:-}" ]]; then
  SHARDS_FILE="$1"
elif [[ -f "$ACTIVE" ]]; then
  SHARDS_FILE="$ACTIVE"
else
  SHARDS_FILE="$CORE"
fi

if [[ ! -f "$SHARDS_FILE" ]]; then
  echo "ERROR: missing $SHARDS_FILE" >&2
  exit 1
fi
echo "== verify-inference-stopped: $SHARDS_FILE =="

# Space-separated IPv4 list. Default: gaming-worker-a-219 Win10 NAT path.
WIN10_NAT_SKIP_HOSTS="${WIN10_NAT_SKIP_HOSTS:-orchestrator}"

skip_win10_nat() {
  local h="$1"
  local tok
  for tok in $WIN10_NAT_SKIP_HOSTS; do
    [[ "$tok" == "$h" ]] && return 0
  done
  return 1
}

fail=0
while read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  read -r host port _rest <<<"$line"
  if skip_win10_nat "$host"; then
    echo "  SKIP $host:$port (Win10 WSL portproxy; verified on-host via gaming-stop)"
    continue
  fi
  if nc -z -w 3 "$host" "$port" 2>/dev/null; then
    echo "  FAIL $host:$port still listening" >&2
    fail=1
  else
    echo "  OK $host:$port closed"
  fi
done <"$SHARDS_FILE"

if [[ "$fail" -ne 0 ]]; then
  echo "ERROR: inference shard stop verify failed (ports still open)" >&2
  exit 1
fi
echo "inference shards stopped (all RPC ports closed)"
