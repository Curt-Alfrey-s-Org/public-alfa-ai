#!/usr/bin/env bash
# LAN bandwidth inventory for Linux cluster peers.
#
# Lists interfaces (ip), addresses, and negotiated link speed (ethtool when
# available). Flags hub-style multiple IPs on one interface and reminds
# that aliases share bandwidth.
#
# Usage:
#   bash scripts/lan-bandwidth-inventory.sh
#   bash scripts/lan-bandwidth-inventory.sh --json   # machine-readable summary
#
# Requires: Linux, ip(8). Optional: ethtool(8).
# Official: ethtool(8) https://man7.org/linux/man-pages/man8/ethtool.8.html
#
# Idempotent: read-only; safe to run repeatedly.
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: lan-bandwidth-inventory.sh requires Linux (use lan-bandwidth-inventory.ps1 on Windows)." >&2
  exit 1
fi

if ! command -v ip >/dev/null 2>&1; then
  echo "ERROR: ip(8) not found. Install iproute2." >&2
  exit 1
fi

json=0
if [[ "${1:-}" == "--json" ]]; then
  json=1
fi

hostname_short="$(hostname -s 2>/dev/null || hostname)"
echo "=== LAN bandwidth inventory: $hostname_short ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "--- ip -br link ---"
ip -br link
echo ""
echo "--- ip -br addr ---"
ip -br addr
echo ""

has_ethtool=0
if command -v ethtool >/dev/null 2>&1; then
  has_ethtool=1
else
  echo "WARN: ethtool not installed; link speed lines omitted (apt install ethtool)." >&2
fi

# Collect UP interfaces (skip lo)
mapfile -t up_ifaces < <(ip -br link | awk '$2 ~ /UP/ && $1 != "lo" {print $1}')

declare -A iface_ips
while IFS= read -r line; do
  iface="${line%% *}"
  rest="${line#* }"
  ips="$(echo "$rest" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?' || true)"
  if [[ -n "$ips" ]]; then
    iface_ips["$iface"]="$ips"
  fi
done < <(ip -br addr)

echo "--- per-interface detail ---"
unused_down=()
wrong_speed=()
alias_groups=()

for iface in "${up_ifaces[@]}"; do
  state="$(ip -br link show "$iface" | awk '{print $2}')"
  carrier="unknown"
  speed="unknown"
  if [[ "$has_ethtool" -eq 1 ]]; then
    ethtool_out="$(ethtool "$iface" 2>/dev/null || true)"
    speed="$(echo "$ethtool_out" | awk -F': ' '/Speed:/{gsub(/[^0-9]/,"",$2); if ($2 != "") print $2; else print "unknown"}' | head -1)"
    [[ -z "$speed" ]] && speed="unknown"
    if echo "$ethtool_out" | grep -q 'Link detected: no'; then
      carrier="down"
    elif echo "$ethtool_out" | grep -q 'Link detected: yes'; then
      carrier="up"
    fi
    if [[ "$speed" == "1000" || "$speed" == "unknown" ]]; then
      # Flag 10G-capable names negotiating at 1G (heuristic)
      if [[ "$iface" =~ np0|np1|10g|enp.*f0 ]]; then
        wrong_speed+=("$iface:${speed}Mb/s")
      fi
    fi
  fi
  addrs="${iface_ips[$iface]:-}"
  ip_count=0
  if [[ -n "$addrs" ]]; then
    ip_count="$(echo "$addrs" | wc -w | tr -d ' ')"
  fi
  echo "iface=$iface state=$state carrier=$carrier speed=${speed}Mb/s ip_count=$ip_count"
  if [[ -n "$addrs" ]]; then
    echo "  addrs: $addrs"
  fi
  if [[ "$ip_count" -gt 1 ]]; then
    alias_groups+=("$iface ($ip_count IPs: $addrs)")
  fi
done

# DOWN interfaces with no carrier (potential idle NICs)
while IFS= read -r line; do
  iface="${line%% *}"
  [[ "$iface" == "lo" ]] && continue
  state="${line#* }"
  if [[ "$state" != *UP* ]]; then
    unused_down+=("$iface")
  fi
done < <(ip -br link)

echo ""
echo "=== summary ==="
echo "Host: $hostname_short"
if [[ "$has_ethtool" -eq 1 ]]; then
  echo "Negotiated speeds (UP interfaces):"
  for iface in "${up_ifaces[@]}"; do
    ethtool_out="$(ethtool "$iface" 2>/dev/null || true)"
    spd="$(echo "$ethtool_out" | grep 'Speed:' | head -1 | sed 's/^[[:space:]]*//')"
    lnk="$(echo "$ethtool_out" | grep 'Link detected:' | head -1 | sed 's/^[[:space:]]*//')"
    echo "  $iface: ${spd:-n/a}, ${lnk:-n/a}"
  done
fi

if [[ ${#unused_down[@]} -gt 0 ]]; then
  echo "DOWN / unused interfaces (cable or enable if intentional spare):"
  for d in "${unused_down[@]}"; do
    echo "  - $d"
  done
else
  echo "No extra DOWN interfaces detected (excluding loopback)."
fi

if [[ ${#alias_groups[@]} -gt 0 ]]; then
  echo "Multi-IP same interface (aliases share one wire -- NOT extra bandwidth):"
  for a in "${alias_groups[@]}"; do
    echo "  - $a"
  done
  echo "  hub pattern: hub / storage / .157 on enp11s0f0np0 share one MAC."
else
  echo "No multi-IP alias groups detected on UP interfaces."
fi

if [[ ${#wrong_speed[@]} -gt 0 ]]; then
  echo "Possible under-speed (10G-class name at 1G or unknown):"
  for w in "${wrong_speed[@]}"; do
    echo "  - $w (try: sudo ethtool -r <iface>)"
  done
fi

echo ""
echo "Reminder: IP aliases on one NIC do not add bandwidth."
echo "See docs/LAN_BANDWIDTH_UTILIZATION.md for P0 cabling and P1 local GGUF policy."

if [[ "$json" -eq 1 ]]; then
  printf '{"host":"%s","up_ifaces":%s,"unused_down":%s,"alias_groups":%s}\n' \
    "$hostname_short" \
    "$(printf '%s\n' "${up_ifaces[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')" \
    "$(printf '%s\n' "${unused_down[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')" \
    "$(printf '%s\n' "${alias_groups[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"
fi
