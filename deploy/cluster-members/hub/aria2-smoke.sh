#!/usr/bin/env bash
# hub hub — JSON-RPC smoke test (paths fixed here; requires ARIA2_RPC_KEY in env).
set -euo pipefail
RPC_URL="http://127.0.0.1:6800/jsonrpc"
SECRET="${ARIA2_RPC_KEY:?export ARIA2_RPC_KEY first (same value as the hub aria2 stack; new rpc key: openssl rand -hex 24). See deploy/aria2/README.md}"

echo "POST $RPC_URL (aria2.getVersion)"
for i in $(seq 1 20); do
  if curl -sS -X POST "$RPC_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"aria2.getVersion\",\"params\":[\"token:${SECRET}\"]}"; then
    echo
    exit 0
  fi
  sleep 1
done

echo "ERROR: aria2 JSON-RPC not ready after 20s: $RPC_URL" >&2
exit 1
