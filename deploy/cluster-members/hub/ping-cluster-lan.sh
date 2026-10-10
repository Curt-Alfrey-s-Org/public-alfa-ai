#!/usr/bin/env bash
# Run on hub hub (operator). One ping each; read-only.
set -euo pipefail
hosts=(1 59 93 100 102 103 105 106 107 110 111 126 148 219 229 240 248 249)
echo "== From $(hostname -s) (ping -c1 -W2 each) =="
for last in "${hosts[@]}"; do
  ip="orchestrator0.${last}"
  if ping -c1 -W2 "$ip" >/dev/null 2>&1; then
    echo "$ip OK"
  else
    echo "$ip FAIL"
  fi
done
