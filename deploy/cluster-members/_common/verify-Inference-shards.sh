#!/usr/bin/env bash
# TCP preflight: every host:port in inference-shards.env must accept connections.
#
# Usage:
#   bash deploy/cluster-members/_common/verify-inference-shards.sh
#   bash .../verify-inference-shards.sh --remote-only
#   bash .../verify-inference-shards.sh /path/to/inference-shards.env
#   bash .../verify-inference-shards.sh --remote-only /path/to/inference-shards.env
#
# --remote-only  skip hub shard (operator start-pool deploys it after remote shards).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
REMOTE_ONLY=0
if [[ "${1:-}" == "--remote-only" ]]; then
  REMOTE_ONLY=1
  shift
fi
SHARDS_FILE="${1:-$REPO_DIR/deploy/llamacpp-rpc/inference-shards.env}"

if [[ ! -f "$SHARDS_FILE" ]]; then
  echo "ERROR: missing $SHARDS_FILE" >&2
  exit 1
fi

fail=0
VERIFY_RETRIES="${inference_VERIFY_RETRIES:-15}"
VERIFY_INTERVAL="${inference_VERIFY_INTERVAL:-2}"
inference_SSH_111_USER="${inference_SSH_111_USER:-operator}"
inference_SSH_111_HOST="${inference_SSH_111_HOST:-hub}"
inference_SSH_111_KEY="${inference_SSH_111_KEY:-$HOME/.ssh/id_ed25519_cluster}"

wait_tcp_once() {
  local host="$1"
  local port="$2"
  nc -z -w 3 "$host" "$port" 2>/dev/null
}

wait_tcp_ssh_loopback() {
  local port="$1"
  local ssh_key="$inference_SSH_111_KEY"
  [[ -f "$ssh_key" ]] || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=10 -i "$ssh_key" \
    "${inference_SSH_111_USER}@${inference_SSH_111_HOST}" \
    "nc -z -w 3 127.0.0.1 ${port}" 2>/dev/null
}

wait_tcp() {
  local host="$1"
  local port="$2"
  local attempt
  for attempt in $(seq 1 "$VERIFY_RETRIES"); do
    if wait_tcp_once "$host" "$port"; then
      return 0
    fi
    if [[ "$attempt" -lt "$VERIFY_RETRIES" ]]; then
      sleep "$VERIFY_INTERVAL"
    fi
  done
  return 1
}

wait_tcp_111_shard() {
  local port="$1"
  local attempt
  for attempt in $(seq 1 "$VERIFY_RETRIES"); do
    if wait_tcp_once "127.0.0.1" "$port"; then
      echo "loopback"
      return 0
    fi
    if wait_tcp_once "$inference_SSH_111_HOST" "$port"; then
      echo "lan"
      return 0
    fi
    if wait_tcp_ssh_loopback "$port"; then
      echo "ssh-loopback"
      return 0
    fi
    if [[ "$attempt" -lt "$VERIFY_RETRIES" ]]; then
      sleep "$VERIFY_INTERVAL"
    fi
  done
  return 1
}

# Hub host (inference): loopback before LAN IP (hairpin / dual-NIC false negatives).
wait_tcp_148_shard() {
  local port="$1"
  local attempt
  for attempt in $(seq 1 "$VERIFY_RETRIES"); do
    if wait_tcp_once "127.0.0.1" "$port"; then
      echo "loopback"
      return 0
    fi
    if wait_tcp_once "orchestrator" "$port"; then
      echo "lan"
      return 0
    fi
    if [[ "$attempt" -lt "$VERIFY_RETRIES" ]]; then
      sleep "$VERIFY_INTERVAL"
    fi
  done
  return 1
}

while read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  read -r host port _rest <<<"$line"
  if [[ "$REMOTE_ONLY" == "1" && "$host" == "hub" ]]; then
    echo "  SKIP $host:$port (remote-only; hub starts on operator step)"
    continue
  fi
  if [[ "$host" == "hub" && "$port" == "31353" ]]; then
    shard_via="$(wait_tcp_111_shard "$port" || true)"
    if [[ -n "$shard_via" ]]; then
      echo "  OK $host:$port ($shard_via)"
    else
      echo "  FAIL $host:$port not reachable (after ${VERIFY_RETRIES} attempts; tried LAN, local loopback, SSH loopback)" >&2
      echo "  HINT: hub 3050 shard - stop Petals worker, then redeploy:" >&2
      echo "    sudo bash ${REPO_DIR}/deploy/cluster-members/hub/deploy-grev27-pool-shard.sh" >&2
      fail=1
    fi
  elif [[ "$host" == "orchestrator" && ( "$port" == "31356" || "$port" == "31357" ) ]]; then
    shard_via="$(wait_tcp_148_shard "$port" || true)"
    if [[ -n "$shard_via" ]]; then
      echo "  OK $host:$port ($shard_via)"
    else
      echo "  FAIL $host:$port not reachable (after ${VERIFY_RETRIES} attempts; tried loopback, LAN)" >&2
      echo "  HINT: inference rpc-server wedged if local nc fails but container Up - redeploy both shards:" >&2
      echo "    ssh operator@orchestrator 'cd ~/alfa-ai && bash deploy/cluster-members/inference-coordinator/deploy-grev27-pool-shard.sh'" >&2
      fail=1
    fi
  elif wait_tcp "$host" "$port"; then
    echo "  OK $host:$port"
  else
    echo "  FAIL $host:$port not reachable (after ${VERIFY_RETRIES} attempts)" >&2
    if [[ "$host" == "orchestrator" && "$port" == "31350" ]]; then
      echo "  HINT: orchestrator WSL mirrored Hyper-V firewall - on orchestrator run install-wsl-lan-firewall.ps1 -Profile operator-93 as operator (Admin); see docs/WINDOWS_WSL_DOCKER_ENGINE.md" >&2
      echo "  See docs/WINDOWS_WSL_DOCKER_ENGINE.md and docs/GREV27_27B_OPERATOR.md" >&2
    fi
    fail=1
  fi
done <"$SHARDS_FILE"

if [[ "$fail" -ne 0 ]]; then
  echo "ERROR: inference shard preflight failed" >&2
  exit 1
fi
echo "inference shards reachable"
