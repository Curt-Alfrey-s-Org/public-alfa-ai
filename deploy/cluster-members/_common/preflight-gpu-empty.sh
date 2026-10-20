#!/usr/bin/env bash
# Fail if any GPU holds more than MAX_MIB used VRAM (default 512).
#
# Run on each host BEFORE starting rpc-server / coordinator load.
# nvidia-smi: https://docs.nvidia.com/deploy/nvidia-smi/
#
# Usage:
#   bash deploy/cluster-members/_common/preflight-gpu-empty.sh
#   MAX_MIB=256 bash .../preflight-gpu-empty.sh
set -euo pipefail

MAX_MIB="${MAX_MIB:-512}"
LABEL="${HOST_LABEL:-$(hostname -s)}"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found on $LABEL" >&2
  exit 1
fi

fail=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  idx="${line%%,*}"
  used="${line##*,}"
  used="$(echo "$used" | tr -d ' MiB')"
  if [[ "$used" -gt "$MAX_MIB" ]]; then
    echo "ERROR: $LABEL GPU $idx: ${used} MiB used (max ${MAX_MIB} MiB)" >&2
    fail=1
  else
    echo "OK $LABEL GPU $idx: ${used} MiB"
  fi
done < <(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null)

if [[ "$fail" -ne 0 ]]; then
  echo "Stop Petals/Ollama/llama containers and re-run preflight." >&2
  exit 1
fi

echo "preflight-gpu-empty OK on $LABEL"
