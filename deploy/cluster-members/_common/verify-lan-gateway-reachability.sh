#!/usr/bin/env bash
# Classify LAN default-gateway health (AXE300 .1 vs hub br1 island).
#
# Usage: bash deploy/cluster-members/_common/verify-lan-gateway-reachability.sh
#
# Exit 0 = gateway and DNS path OK; exit 1 = island partition (LAN east-west may still work).
# See docs/LAN_ISLAND_GATEWAY_OUTAGE.md
set -euo pipefail

GW="${ALFA_LAN_GATEWAY:-orchestrator}"
DNS_PROBE="${ALFA_LAN_DNS_PROBE:-1.1.1.1}"
HUB="${ALFA_LAN_HUB_IP:-hub}"

fail=0

ping_one() {
  ping -c1 -W2 "$1" >/dev/null 2>&1
}

echo "== LAN gateway reachability =="
echo "host: $(hostname -s)  gw: $GW  hub: $HUB"

if ping_one "$GW"; then
  echo "OK  ping $GW (default gateway)"
else
  echo "FAIL ping $GW (ARP or L2 to AXE300 missing?)"
  fail=1
fi

if ping_one "$DNS_PROBE"; then
  echo "OK  ping $DNS_PROBE (WAN path)"
else
  echo "FAIL ping $DNS_PROBE (no internet egress)"
  fail=1
fi

if ping_one "$HUB"; then
  echo "OK  ping $HUB (hub br1 / hub mgmt)"
else
  echo "WARN ping $HUB (hub mgmt unreachable from this host)"
fi

if command -v getent >/dev/null 2>&1; then
  if getent hosts github.com >/dev/null 2>&1; then
    echo "OK  DNS github.com"
  else
    echo "FAIL DNS github.com (cluster git fetch will fail without hub file:// origin)"
    fail=1
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  echo "PASS: router path healthy"
  exit 0
fi

echo "FAIL: likely br1 island partition -- see docs/LAN_ISLAND_GATEWAY_OUTAGE.md"
exit 1
