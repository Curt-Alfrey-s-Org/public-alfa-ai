#!/usr/bin/env bash
# Run on hub hub when github.com does not resolve.
# Policy: nameserver is AXE300 only (orchestrator); AdGuard edge is configured on the router.
# See docs/CLUSTER_DNS_AND_GATEWAY.md
#
# Official API: network.configuration.update (hub SCALE API docs).
set -euo pipefail

GW_DNS="${ALFA_LAN_DNS:-orchestrator}"

midclt call network.configuration.update "{\"nameserver1\": \"${GW_DNS}\", \"nameserver2\": \"\", \"nameserver3\": \"\"}"
sleep 2
if getent hosts github.com >/dev/null; then
  echo "OK: github.com resolves via ${GW_DNS}"
  getent hosts github.com
  exit 0
fi

echo "WARN: github.com still does not resolve after nameserver=${GW_DNS}" >&2
echo "Check: ping -c2 ${GW_DNS} (gateway must answer before DNS works)" >&2
exit 1
