#!/usr/bin/env bash
# Validate inference-shards.env (or inference_SHARDS_FILE) and print TENSOR_SPLIT preview.
# Does not write .env.rpc — use write-grev27-pool-env-from-shards.sh for that.
#
# Usage:
#   bash deploy/cluster-members/_common/validate-inference-shards.sh
#   inference_SHARDS_FILE=deploy/llamacpp-rpc/inference-shards.no-1660s.env \
#     bash deploy/cluster-members/_common/validate-inference-shards.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
SHARDS_FILE="${inference_SHARDS_FILE:-$LLC/inference-shards.env}"

if [[ ! -f "$SHARDS_FILE" ]]; then
  echo "ERROR: missing shard list: $SHARDS_FILE" >&2
  exit 1
fi

backends=()
splits=()
n=0
while read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  read -r host port vram_gb pct <<<"$line"
  if [[ -z "$host" || -z "$port" || -z "$vram_gb" ]]; then
    echo "ERROR: bad shard line: $line" >&2
    exit 1
  fi
  if [[ -n "${pct:-}" ]]; then
    ts="$(awk -v gb="$vram_gb" -v p="$pct" 'BEGIN { printf "%.1f", gb * p / 100 }')"
  else
    ts="$vram_gb"
  fi
  n=$((n + 1))
  backends+=("${host}:${port}")
  splits+=("$ts")
  echo "  [$n] ${host}:${port}  -ts=${ts}  (vram_gb=${vram_gb}${pct:+ pct=${pct}})"
done <"$SHARDS_FILE"

if [[ "${#backends[@]}" -lt 2 ]]; then
  echo "ERROR: need at least 2 shards (found ${#backends[@]})" >&2
  exit 1
fi

RPC_BACKENDS="$(IFS=,; echo "${backends[*]}")"
TENSOR_SPLIT="$(IFS=,; echo "${splits[*]}")"
sum="$(echo "$TENSOR_SPLIT" | awk -F, '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%.1f", s}')"

echo "OK: $SHARDS_FILE ($n shards)"
echo "  RPC_BACKENDS=$RPC_BACKENDS"
echo "  TENSOR_SPLIT=$TENSOR_SPLIT (sum=${sum} GB nominal)"
echo "Add/remove/reorder lines in the shards file, then regenerate .env.rpc on hub and full stop+start."
