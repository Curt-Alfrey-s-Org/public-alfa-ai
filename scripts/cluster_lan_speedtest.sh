#!/usr/bin/env bash
# Proper cluster LAN speed test orchestrator for ALFa AI.
#
# Runs from any cluster node (typically inference hub) and measures:
#   Phase 1: ICMP ping stats (avg RTT, jitter/mdev, loss)
#   Phase 2: TCP reachability probe on iperf3 port
#   Phase 3: iperf3 UPLOAD  (this host -> target)  via --json, parsed
#   Phase 3: iperf3 DOWNLOAD (target -> this host) via --json, parsed (-R)
#   Final  : aligned summary table + per-host remediation block
#
# Environment readiness:
#   - Verifies this host has iperf3, ping, nc, python3, awk on PATH.
#   - --auto-install will apt-get/dnf/apk install iperf3 if missing.
#   - For each target, if tcp/<port> is CLOSED, the script prints the EXACT
#     bootstrap command to run on that host (scripts/iperf3-bootstrap.{sh,ps1})
#     and continues testing the hosts that are up. No partial cascade failures.
#
# Logging:
#   Full transcript is mirrored to cluster-speedtest-<UTC>.log in CWD.
#
# Exit codes:
#   0 = every target passed ping AND iperf3 upload + download
#   1 = at least one target failed some phase
#   2 = this host's environment is not ready (unfixed by --auto-install)
#
# Usage:
#   bash scripts/cluster_lan_speedtest.sh
#   bash scripts/cluster_lan_speedtest.sh --auto-install
#   bash scripts/cluster_lan_speedtest.sh --hosts hub,orchestrator
#   bash scripts/cluster_lan_speedtest.sh --file scripts/cluster_speedtest.hosts.example.bak
#   bash scripts/cluster_lan_speedtest.sh --duration 20 --streams 8
#   bash scripts/cluster_lan_speedtest.sh --ping-only
#   bash scripts/cluster_lan_speedtest.sh --no-ping
#   bash scripts/cluster_lan_speedtest.sh --port 5202
#
# Env overrides (backward compat):
#   CLUSTER_SPEEDTEST_IPS   space-separated target list (overrides defaults)
#   IPERF_PORT              iperf3 port (default 5201)
set -euo pipefail

# ----------------------------- defaults -----------------------------------
DEFAULT_HOSTS=(
  hub   # hub 'hub' (brain + hub, br1 mgmt)
  orchestrator   # hub NFS VIP on br1 (same L2 as hub)
  orchestrator   # RETIRED Petals plane (historical iperf target only)
  apps   # Ubuntu apps host (auto-filtered if we ARE this host)
  orchestrator    # operator-93 (Win11)
  orchestrator   # gaming-worker-b-249 (Win11, Blackwell)
  orchestrator    # gaming-worker-c-59 (Win11, Blackwell)
  orchestrator   # gaming-worker-a-219 (Win11, Blackwell)
)

PORT="${IPERF_PORT:-5201}"
DURATION=10
STREAMS=4
MODE=both            # both | ping | iperf
AUTO_INSTALL=0
HOSTS_ARG=""
HOSTS_FILE=""

# ----------------------------- argparse -----------------------------------
usage() {
  sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosts)        HOSTS_ARG="${2:?}"; shift 2 ;;
    --file|-f)      HOSTS_FILE="${2:?}"; shift 2 ;;
    --port)         PORT="${2:?}"; shift 2 ;;
    --duration|-t)  DURATION="${2:?}"; shift 2 ;;
    --streams|-P)   STREAMS="${2:?}"; shift 2 ;;
    --ping-only)    MODE=ping; shift ;;
    --no-ping)      MODE=iperf; shift ;;
    --auto-install) AUTO_INSTALL=1; shift ;;
    -h|--help)      usage 0 ;;
    *)              echo "Unknown argument: $1 (use --help)" >&2; usage 2 ;;
  esac
done

# --------------------------- env readiness --------------------------------
log()  { printf '[env] %s\n' "$*"; }
die()  { printf '[env] ERROR: %s\n' "$*" >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }

install_iperf3() {
  if   have apt-get; then sudo apt-get update -qq && sudo apt-get install -y iperf3
  elif have dnf;     then sudo dnf install -y iperf3
  elif have apk;     then sudo apk add --no-cache iperf3
  elif have pacman;  then sudo pacman -S --noconfirm iperf3
  else return 1
  fi
}

if ! have iperf3; then
  if [[ "$AUTO_INSTALL" == "1" ]]; then
    log "iperf3 missing; auto-installing..."
    install_iperf3 || die "Could not install iperf3 via known package managers. Install manually."
  else
    echo "[env] ERROR: iperf3 not found on this host." >&2
    echo "[env]   Fix:  sudo apt-get install -y iperf3    # or equivalent" >&2
    echo "[env]   Or:   re-run with --auto-install" >&2
    exit 2
  fi
fi

for tool in ping awk python3; do
  have "$tool" || die "required tool '$tool' not on PATH"
done

if ! have nc && ! have timeout; then
  die "need either 'nc' (netcat) or 'timeout' for TCP probes"
fi

# -------------------------- target list -----------------------------------
if [[ -n "$HOSTS_ARG" ]]; then
  IFS=',' read -r -a RAW_HOSTS <<< "$HOSTS_ARG"
elif [[ -n "${CLUSTER_SPEEDTEST_IPS:-}" ]]; then
  read -r -a RAW_HOSTS <<< "${CLUSTER_SPEEDTEST_IPS}"
elif [[ -n "$HOSTS_FILE" ]]; then
  [[ -f "$HOSTS_FILE" ]] || die "hosts file not found: $HOSTS_FILE"
  mapfile -t RAW_HOSTS < <(grep -vE '^\s*($|#)' "$HOSTS_FILE" | tr -d '\r')
else
  RAW_HOSTS=( "${DEFAULT_HOSTS[@]}" )
fi

# Filter self and blanks. Exclude docker/podman bridge IPs (172.16.0.0/12 is
# noisy on hosts running Docker Desktop / docker-compose bridges).
MY_IPS=()
while read -r ip; do
  [[ -z "$ip" ]] && continue
  case "$ip" in
    172.*) continue ;;   # docker/podman bridges
    169.254.*) continue ;;
    127.*) continue ;;
  esac
  MY_IPS+=( "$ip" )
done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.')

HOSTS=()
for host in "${RAW_HOSTS[@]}"; do
  host="${host// /}"
  [[ -z "$host" ]] && continue
  self=0
  for mine in "${MY_IPS[@]}"; do
    [[ "$host" == "$mine" ]] && self=1 && break
  done
  if [[ "$self" == "1" ]]; then
    log "Skipping self: $host"
  else
    HOSTS+=( "$host" )
  fi
done

if [[ "${#HOSTS[@]}" -eq 0 ]]; then
  die "no targets to test after filtering self / blanks"
fi

# ------------------------------- logging ---------------------------------
LOG="cluster-speedtest-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG")
exec 2>&1

echo "=============================================================="
echo " ALFa AI cluster LAN speed test"
echo "=============================================================="
echo " Started:    $(date -Iseconds)"
echo " Source:     $(hostname) (${MY_IPS[*]:-unknown})"
echo " iperf3:     $(iperf3 --version 2>&1 | head -1)"
echo " Targets:    ${HOSTS[*]}"
echo " Port:       $PORT"
echo " Duration:   ${DURATION}s"
echo " Streams:    $STREAMS"
echo " Mode:       $MODE"
echo " Log file:   $LOG"
echo "=============================================================="
echo ""

# ------------------------------ data store --------------------------------
declare -A PING_AVG PING_JITTER PING_LOSS
declare -A PORT_STATUS
declare -A UP_MBPS DN_MBPS
declare -A UP_RETR DN_RETR
declare -A STATUS FIX_HINT

# ------------------------------ helpers -----------------------------------
port_open() {
  local ip=$1
  if have nc; then
    nc -z -w 2 "$ip" "$PORT" >/dev/null 2>&1
  else
    timeout 2 bash -c "echo >/dev/tcp/$ip/$PORT" >/dev/null 2>&1
  fi
}

parse_iperf_json() {
  # $1 = path to json, $2 = 'sum_sent' or 'sum_received'
  local path=$1 key=$2
  python3 - "$path" "$key" <<'PY' 2>/dev/null || echo ''
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    summary = d.get("end", {}).get(sys.argv[2]) or {}
    bps = float(summary.get("bits_per_second") or 0)
    retr = int(summary.get("retransmits") or 0) if sys.argv[2] == "sum_sent" else ""
    if bps <= 0:
        sys.exit(0)
    print(f"{bps/1e6:.1f}|{retr}")
except Exception:
    sys.exit(0)
PY
}

bootstrap_hint_for() {
  local ip=$1
  case "$ip" in
    hub)
      cat <<EOF
      -> iperf3 server MISSING on $ip (hub Scale). On hub as operator:
           cd /mnt/hub/alfa-ai/repo/alfa-ai && git pull
           bash scripts/iperf3-bootstrap.sh
EOF
      ;;
    orchestrator)
      cat <<EOF
      -> iperf3 server MISSING on $ip (operator-93, Win11). Administrator PowerShell:
           cd C:\\alfa-ai ; git pull
           powershell -ExecutionPolicy Bypass -File scripts\\iperf3-bootstrap.ps1
EOF
      ;;
    orchestrator|orchestrator|orchestrator)
      cat <<EOF
      -> iperf3 server MISSING on $ip (Win11 worker). Administrator PowerShell:
           cd C:\\alfa-ai-worker ; git pull
           powershell -ExecutionPolicy Bypass -File scripts\\iperf3-bootstrap.ps1
EOF
      ;;
    apps)
      cat <<EOF
      -> iperf3 server MISSING on $ip (Ubuntu apps host). On apps:
           cd ~/alfa-ai && git pull
           bash scripts/iperf3-bootstrap.sh
EOF
      ;;
    orchestrator|orchestrator)
      cat <<EOF
      -> $ip is a hub NIC alias of hub. TCP/$PORT may be bound only on
         hub itself. Either test hub or re-bind iperf3 to
         this alias with 'iperf3 -s -p $PORT -B $ip' on hub.
EOF
      ;;
    *)
      cat <<EOF
      -> iperf3 server MISSING on $ip. Run the appropriate bootstrap:
           Linux:   bash scripts/iperf3-bootstrap.sh
           Windows: powershell -ExecutionPolicy Bypass -File scripts\\iperf3-bootstrap.ps1
EOF
      ;;
  esac
}

# ------------------------------ Phase 1: ping -----------------------------
ping_target() {
  local ip=$1
  local tmp rc
  tmp=$(mktemp)
  set +e
  ping -c 5 -W 2 "$ip" >"$tmp" 2>&1
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    local rtt_line loss avg mdev
    rtt_line=$(grep -E '^(rtt|round-trip)' "$tmp" || true)
    loss=$(grep -oE '[0-9.]+% packet loss' "$tmp" | head -1 | awk '{print $1}')
    if [[ -n "$rtt_line" ]]; then
      avg=$(echo "$rtt_line" | awk -F'=' '{print $2}' | awk -F'/' '{print $2}')
      mdev=$(echo "$rtt_line" | awk -F'=' '{print $2}' | awk -F'/' '{print $4}' | awk '{print $1}')
    else
      avg="?"; mdev="?"
    fi
    PING_AVG[$ip]="$avg"
    PING_JITTER[$ip]="$mdev"
    PING_LOSS[$ip]="${loss:-0%}"
    printf 'PING %-15s  avg=%sms  jitter=%sms  loss=%s\n' \
      "$ip" "$avg" "$mdev" "${loss:-0%}"
  else
    PING_AVG[$ip]="DOWN"
    PING_JITTER[$ip]="-"
    PING_LOSS[$ip]="100%"
    printf 'PING %-15s  FAIL (no reply within 5x2s)\n' "$ip"
  fi
  rm -f "$tmp"
}

if [[ "$MODE" != "iperf" ]]; then
  echo "=== Phase 1: ping (5 packets, 2s timeout) ==="
  for ip in "${HOSTS[@]}"; do
    ping_target "$ip"
  done
  echo ""
fi

# ------------------------------ Phase 2: probe ----------------------------
if [[ "$MODE" != "ping" ]]; then
  echo "=== Phase 2: TCP reachability on :$PORT ==="
  for ip in "${HOSTS[@]}"; do
    if port_open "$ip"; then
      PORT_STATUS[$ip]=OPEN
      printf 'PORT %-15s  %5d/tcp OPEN\n' "$ip" "$PORT"
    else
      PORT_STATUS[$ip]=CLOSED
      FIX_HINT[$ip]="$(bootstrap_hint_for "$ip")"
      printf 'PORT %-15s  %5d/tcp CLOSED\n' "$ip" "$PORT"
    fi
  done
  echo ""

# ------------------------------ Phase 3: iperf3 ---------------------------
  echo "=== Phase 3: iperf3 throughput (t=${DURATION}s, P=${STREAMS}) ==="
  for ip in "${HOSTS[@]}"; do
    if [[ "${PORT_STATUS[$ip]}" != "OPEN" ]]; then
      UP_MBPS[$ip]=SKIP; DN_MBPS[$ip]=SKIP
      UP_RETR[$ip]="-"; DN_RETR[$ip]="-"
      STATUS[$ip]=NO_SERVER
      continue
    fi

    echo "---- $ip ----"

    # UPLOAD: this host -> target (data sent by client -> parse sum_sent)
    tmp_up=$(mktemp)
    set +e
    iperf3 -c "$ip" -p "$PORT" -t "$DURATION" -P "$STREAMS" --json >"$tmp_up" 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      parsed=$(parse_iperf_json "$tmp_up" sum_sent)
      if [[ -n "$parsed" ]]; then
        UP_MBPS[$ip]="${parsed%%|*}"
        UP_RETR[$ip]="${parsed##*|}"
        printf '  UPLOAD   %s Mbps (retr=%s)\n' "${UP_MBPS[$ip]}" "${UP_RETR[$ip]}"
      else
        UP_MBPS[$ip]=PARSE
        UP_RETR[$ip]="-"
        echo "  UPLOAD   FAIL: could not parse iperf3 JSON (see $LOG)"
        echo "  ---- iperf3 output (tail) ----"
        tail -20 "$tmp_up" | sed 's/^/    /'
      fi
    else
      UP_MBPS[$ip]=FAIL
      UP_RETR[$ip]="-"
      echo "  UPLOAD   FAIL (iperf3 exit $rc)"
      tail -20 "$tmp_up" | sed 's/^/    /'
    fi
    rm -f "$tmp_up"

    sleep 2

    # DOWNLOAD: target -> this host (-R, parse sum_received)
    tmp_dn=$(mktemp)
    set +e
    iperf3 -c "$ip" -p "$PORT" -t "$DURATION" -P "$STREAMS" -R --json >"$tmp_dn" 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      parsed=$(parse_iperf_json "$tmp_dn" sum_received)
      if [[ -n "$parsed" ]]; then
        DN_MBPS[$ip]="${parsed%%|*}"
        DN_RETR[$ip]="-"
        printf '  DOWNLOAD %s Mbps\n' "${DN_MBPS[$ip]}"
      else
        DN_MBPS[$ip]=PARSE
        DN_RETR[$ip]="-"
        echo "  DOWNLOAD FAIL: could not parse iperf3 JSON (see $LOG)"
        echo "  ---- iperf3 output (tail) ----"
        tail -20 "$tmp_dn" | sed 's/^/    /'
      fi
    else
      DN_MBPS[$ip]=FAIL
      DN_RETR[$ip]="-"
      echo "  DOWNLOAD FAIL (iperf3 exit $rc)"
      tail -20 "$tmp_dn" | sed 's/^/    /'
    fi
    rm -f "$tmp_dn"

    # Status
    if [[ "${UP_MBPS[$ip]}" =~ ^[0-9.]+$ && "${DN_MBPS[$ip]}" =~ ^[0-9.]+$ ]]; then
      STATUS[$ip]=OK
    else
      STATUS[$ip]=IPERF_ERR
      FIX_HINT[$ip]="$(bootstrap_hint_for "$ip")"
    fi
    echo ""
  done
fi

# ------------------------------ Summary -----------------------------------
echo "=============================================================="
echo " Summary"
echo "=============================================================="
printf '%-15s  %-9s  %-9s  %-6s  %-10s  %-10s  %s\n' \
  'Target' 'Ping ms' 'Jitter' 'Loss' 'Up Mbps' 'Dn Mbps' 'Status'
printf '%-15s  %-9s  %-9s  %-6s  %-10s  %-10s  %s\n' \
  '---------------' '---------' '---------' '------' '----------' '----------' '----------'

fail_count=0
for ip in "${HOSTS[@]}"; do
  st="${STATUS[$ip]:-UNKNOWN}"
  if [[ "$MODE" == "ping" ]]; then
    if [[ "${PING_AVG[$ip]}" == "DOWN" ]]; then
      st="DOWN"
      FIX_HINT[$ip]="      -> $ip is not responding to ICMP. Check: powered on, on the LAN, and not asleep (Windows fast-startup / WiFi power save). If the host uses WiFi, prefer wiring it for stable cluster membership."
    else
      st="OK"
    fi
  fi
  printf '%-15s  %-9s  %-9s  %-6s  %-10s  %-10s  %s\n' \
    "$ip" \
    "${PING_AVG[$ip]:--}" \
    "${PING_JITTER[$ip]:--}" \
    "${PING_LOSS[$ip]:--}" \
    "${UP_MBPS[$ip]:--}" \
    "${DN_MBPS[$ip]:--}" \
    "$st"
  case "$st" in
    OK) ;;
    *)  fail_count=$((fail_count+1)) ;;
  esac
done
echo ""

# Remediation block -- only emit if we actually have hints to print.
hint_count=0
for ip in "${HOSTS[@]}"; do
  [[ -n "${FIX_HINT[$ip]:-}" ]] && hint_count=$((hint_count+1))
done
if [[ "$hint_count" -gt 0 ]]; then
  echo "=============================================================="
  echo " Remediation (run the hinted command on each affected host)"
  echo "=============================================================="
  for ip in "${HOSTS[@]}"; do
    if [[ -n "${FIX_HINT[$ip]:-}" ]]; then
      echo ""
      echo "[$ip]"
      echo "${FIX_HINT[$ip]}"
    fi
  done
  echo ""
fi

echo "Finished: $(date -Iseconds)"
echo "Transcript: $LOG"

exit $(( fail_count > 0 ? 1 : 0 ))
