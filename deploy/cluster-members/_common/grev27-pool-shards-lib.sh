#!/usr/bin/env bash
# Parse grev27-pool-shards.env -> RPC_BACKENDS, TENSOR_SPLIT, host:port list.
# Source from write-grev27-pool-env.sh and deploy-grev27-pool-coordinator.sh.
#
# Exports after grev27_load_shards:
#   GREV27_RPC_BACKENDS, GREV27_TENSOR_SPLIT, GREV27_SHARD_HOST_PORTS (array)
set -euo pipefail

_grev27_shards_file() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "${GREV27_POOL_SHARDS_FILE:-$here/grev27-pool-shards.env}"
}

grev27_load_shards() {
  local f="$(_grev27_shards_file)"
  local line host port vram_gb pct ts_val
  GREV27_RPC_BACKENDS=""
  GREV27_TENSOR_SPLIT=""
  GREV27_SHARD_HOST_PORTS=()

  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing shard registry $f" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue

    IFS=: read -r host port vram_gb pct <<< "$line"
    if [[ -z "${host:-}" || -z "${port:-}" || -z "${vram_gb:-}" ]]; then
      echo "ERROR: bad shard line in $f: $line" >&2
      return 1
    fi
    pct="${pct:-100}"
    ts_val="$(awk -v gb="$vram_gb" -v p="$pct" 'BEGIN { printf "%.1f", gb * p / 100 }' | sed 's/\.0$//')"

    GREV27_SHARD_HOST_PORTS+=("${host}:${port}")
    if [[ -n "$GREV27_RPC_BACKENDS" ]]; then
      GREV27_RPC_BACKENDS+=","
      GREV27_TENSOR_SPLIT+=","
    fi
    GREV27_RPC_BACKENDS+="${host}:${port}"
    GREV27_TENSOR_SPLIT+="${ts_val}"
  done < "$f"

  if [[ ${#GREV27_SHARD_HOST_PORTS[@]} -eq 0 ]]; then
    echo "ERROR: no active shards in $f" >&2
    return 1
  fi

  export GREV27_RPC_BACKENDS GREV27_TENSOR_SPLIT GREV27_SHARD_HOST_PORTS
}

grev27_verify_shards_reachable() {
  local hp host port
  grev27_load_shards || return 1
  for hp in "${GREV27_SHARD_HOST_PORTS[@]}"; do
    host="${hp%%:*}"
    port="${hp##*:}"
    if ! nc -z -w 3 "$host" "$port" 2>/dev/null; then
      echo "ERROR: rpc-server not reachable at $hp" >&2
      return 1
    fi
    echo "  OK $hp"
  done
}

grev27_print_shard_registry() {
  local f="$(_grev27_shards_file)"
  echo "Shard registry: $f"
  grev27_load_shards || return 1
  echo "  RPC_BACKENDS=$GREV27_RPC_BACKENDS"
  echo "  TENSOR_SPLIT=$GREV27_TENSOR_SPLIT"
  echo "  shard_count=${#GREV27_SHARD_HOST_PORTS[@]}"
}
