#!/usr/bin/env bash
set -euo pipefail
RPC_URL="http://hub/jsonrpc"
SECRET="${ARIA2_RPC_KEY:?export ARIA2_RPC_KEY first (same value as the hub aria2 stack; new rpc key: openssl rand -hex 24). See deploy/aria2/README.md}"

echo "POST $RPC_URL (aria2.getVersion via hub)"
for i in $(seq 1 20); do
  if curl -sS -X POST "$RPC_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"aria2.getVersion\",\"params\":[\"token:${SECRET}\"]}"; then
    echo
    exit 0
  fi
  sleep 1
done

echo "ERROR: hub aria2 RPC unreachable after 20s: $RPC_URL" >&2
exit 1
