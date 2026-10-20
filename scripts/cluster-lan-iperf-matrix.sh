#!/usr/bin/env bash
# Run iperf3 client tests from this host to cluster IPs (servers on :5201).
#
# Common clients: inference (LACP / production NFS path) or apps (apps vantage).
# apps as client does NOT mean apps is the embed host -- RAG is on inference:11435/8360.
#
# Env:
#   IPERF3_PORT       (default 5201)
#   IPERF3_DURATION   (default 5)
#   IPERF3_PARALLEL   (default 1; use 4 for LACP / multi-flow checks from inference)
#   IPERF3_TARGETS    optional "name:ip" space-separated list (overrides mode)
#   LOAD_NOTE         free-text label when cluster is under load (not idle baseline)
#
# Usage:
#   bash scripts/cluster-lan-iperf-matrix.sh [client_label]
#   bash scripts/cluster-lan-iperf-matrix.sh --under-load [client_label]
#   IPERF3_INCLUDE_LEGACY=1 bash scripts/cluster-lan-iperf-matrix.sh full-survey
#
# Production default targets: orchestrator, pool-opt-in, hub, storage (NFS VIP on br1), inference
# Optional legacy: .104, .147 (retired data-plane IPs) via IPERF3_INCLUDE_LEGACY=1
#
# Official refs: iperf3 https://software.es.net/iperf/
# Proxmox bridges: https://pve.proxmox.com/wiki/Network_Configuration
set -euo pipefail

UNDER_LOAD=0
CLIENT_LABEL=""

for arg in "$@"; do
  case "$arg" in
    --under-load)
      UNDER_LOAD=1
      ;;
    *)
      if [[ -z "$CLIENT_LABEL" ]]; then
        CLIENT_LABEL="$arg"
      fi
      ;;
  esac
done

CLIENT_LABEL="${CLIENT_LABEL:-$(hostname -s)}"
PORT="${IPERF3_PORT:-5201}"
DURATION="${IPERF3_DURATION:-5}"
PARALLEL="${IPERF3_PARALLEL:-1}"

if [[ "$UNDER_LOAD" -eq 1 && -z "${LOAD_NOTE:-}" ]]; then
  LOAD_NOTE="under-load (inference and/or apps running)"
fi

# Production paths for alfa-ai (embed on inference, not apps/pool-opt-in)
PRODUCTION_TARGETS=(
  "93-mgmt:orchestrator"
  "100-mgmt:orchestrator"
  "111-mgmt:hub"
  "111-nfs:orchestrator"   # NFS VIP on br1 (same L2 as hub)
  "148-mgmt:orchestrator"
)

LEGACY_TARGETS=(
  "104-data:orchestrator"
  "147-data:orchestrator"
)

OPTIONAL_TARGETS=(
  "105-mgmt:apps"
  "111-petals:orchestrator"   # RETIRED Petals VIP (historical matrix only)
  "59-gaming-worker-c:orchestrator"
  "219-gaming-worker-a:orchestrator"
  "249-gaming-worker-b:orchestrator"
  "229-pve:orchestrator"
)

if [[ -n "${IPERF3_TARGETS:-}" ]]; then
  # shellcheck disable=SC2206
  TARGETS=($IPERF3_TARGETS)
elif [[ "${IPERF3_INCLUDE_LEGACY:-0}" == "1" || "${IPERF3_FULL_SURVEY:-0}" == "1" ]]; then
  TARGETS=("${PRODUCTION_TARGETS[@]}" "${LEGACY_TARGETS[@]}" "${OPTIONAL_TARGETS[@]}")
else
  TARGETS=("${PRODUCTION_TARGETS[@]}")
fi

printf 'LAN iperf matrix client=%s port=%s duration=%ss parallel=%s\n' \
  "$CLIENT_LABEL" "$PORT" "$DURATION" "$PARALLEL"
if [[ -n "${LOAD_NOTE:-}" ]]; then
  printf 'WARNING: under-load run -- not an idle baseline (%s)\n' "$LOAD_NOTE"
fi
printf '%-22s %-16s %-10s %-12s %s\n' "TARGET" "IP" "TCP" "Mbps" "NOTES"
printf '%s\n' "--------------------------------------------------------------------------------"

for entry in "${TARGETS[@]}"; do
  name="${entry%%:*}"
  ip="${entry##*:}"
  tcp="FAIL"
  mbps="-"
  notes=""

  if nc -z -w5 "$ip" "$PORT" 2>/dev/null; then
    tcp="OK"
    out="$(iperf3 -c "$ip" -p "$PORT" -t "$DURATION" -P "$PARALLEL" --connect-timeout 5000 2>&1)" || true
    if echo "$out" | grep -q 'sender'; then
      mbps="$(echo "$out" | awk '/sender/ {print $7, $8; exit}')"
    else
      notes="iperf failed"
      mbps="ERR"
    fi
  else
    notes="no iperf server / filtered"
  fi

  printf '%-22s %-16s %-10s %-12s %s\n' "$name" "$ip" "$tcp" "$mbps" "$notes"
done
