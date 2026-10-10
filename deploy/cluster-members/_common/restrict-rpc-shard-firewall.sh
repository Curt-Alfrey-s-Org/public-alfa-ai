#!/usr/bin/env bash
# Restrict llama.cpp rpc-server shard ports to the coordinator only (LAN allowlist).
#
# WHY: rpc-server binds 0.0.0.0 and the upstream README warns it is insecure and
# MUST be firewalled to the LAN. Beyond that, ANY stray client that connects and
# sends non-HELLO bytes (port scan, monitoring probe, a second coordinator) can
# corrupt a shard's session ("Expected HELLO command, update client") and wedge
# it -- which then crashes the real coordinator on its next decode. So we allow
# ONLY the coordinator IP (and loopback) to reach the shard RPC ports; everything
# else is rejected.
#   Official: https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
#
# Idempotent. Loopback is always allowed first (coordinator-local :31353 uses it).
#
# Usage (operator, on each Linux shard host, e.g. inference):
#   sudo COORDINATOR_IP=hub RPC_PORTS="31356 31357" \
#     bash deploy/cluster-members/_common/restrict-rpc-shard-firewall.sh
#
#   # hub (local shard :31353 is loopback-only; coordinator is local):
#   sudo COORDINATOR_IP=hub RPC_PORTS="31353" \
#     bash deploy/cluster-members/_common/restrict-rpc-shard-firewall.sh
#
# Env:
#   COORDINATOR_IP   allowed remote source (default hub)
#   RPC_PORTS        space-separated TCP ports to protect (default "31356 31357")
#   DRY_RUN=1        print the rules that would be applied, change nothing
set -euo pipefail

COORDINATOR_IP="${COORDINATOR_IP:-hub}"
RPC_PORTS="${RPC_PORTS:-31356 31357}"
DRY_RUN="${DRY_RUN:-0}"

if ! command -v iptables >/dev/null 2>&1; then
  echo "ERROR: iptables not found; install iptables or apply an equivalent nft allowlist" >&2
  exit 1
fi

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  DRY_RUN: $*"
  else
    "$@"
  fi
}

# Insert a rule only if an equivalent one is not already present (idempotent).
ensure_rule() {
  # $1 = full iptables spec after the table/chain action verb, used for both -C and -I
  local spec="$1"
  # shellcheck disable=SC2086
  if iptables -C $spec 2>/dev/null; then
    echo "  present: iptables $spec"
    return 0
  fi
  # shellcheck disable=SC2086
  run iptables -I $spec
  echo "  added:   iptables -I $spec"
}

echo "== restrict-rpc-shard-firewall: coordinator=$COORDINATOR_IP ports=[$RPC_PORTS] dry_run=$DRY_RUN =="

for port in $RPC_PORTS; do
  # Order matters: loopback ACCEPT and coordinator ACCEPT must sit ABOVE the DROP.
  # We insert DROP first, then the ACCEPTs (each -I prepends), so final order is:
  #   ACCEPT lo -> ACCEPT coordinator -> DROP others.
  ensure_rule "INPUT -p tcp --dport ${port} -j DROP"
  ensure_rule "INPUT -p tcp -s ${COORDINATOR_IP} --dport ${port} -j ACCEPT"
  ensure_rule "INPUT -i lo -p tcp --dport ${port} -j ACCEPT"
done

echo "== rpc shard firewall allowlist applied (coordinator + loopback only) =="
echo "   verify: sudo iptables -L INPUT -n --line-numbers | grep -E '$(echo "$RPC_PORTS" | tr ' ' '|')'"
if [[ "$DRY_RUN" != "1" ]]; then
  echo "   NOTE: rules are not persisted across reboot unless you use iptables-persistent / netfilter-persistent."
fi
