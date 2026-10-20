#!/usr/bin/env bash
# Cap AMD CPU max frequency on hub (Ryzen 7900X). Keeps turbo enabled but limits
# the policy ceiling (default 5.3 GHz = 5300000 kHz). Softer than disable-cpu-
# boost.sh (base ~4.7 GHz).
#
# Official cpufreq sysfs (scaling_max_freq in kHz):
# https://docs.kernel.org/admin-guide/pm/cpufreq.html
#
# Usage:
#   sudo bash deploy/cluster-members/hub/cap-cpu-max-freq.sh
#   ALFA_CPU_MAX_FREQ_MHZ=5300 sudo bash .../cap-cpu-max-freq.sh
set -euo pipefail

LOG_TAG="alfa-cap-cpu-max-freq"
MAX_MHZ="${ALFA_CPU_MAX_FREQ_MHZ:-5300}"
MAX_KHZ=$((MAX_MHZ * 1000))
MAX_WAIT_SEC="${ALFA_CPU_CAP_WAIT_SEC:-120}"
INTERVAL_SEC=2
BOOST_PATH="/sys/devices/system/cpu/cpufreq/boost"

log() {
  echo "[$LOG_TAG] $*"
}

apply_cap() {
  local changed=0

  # Prefer 5.3 GHz cap over the older full boost-off hook if both were ever run.
  if [[ -w "$BOOST_PATH" ]] && [[ "$(cat "$BOOST_PATH")" == "0" ]]; then
    echo 1 >"$BOOST_PATH"
    log "re-enabled cpufreq boost (cap uses scaling_max_freq, not boost-off)"
  fi

  local path
  for path in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq \
              /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
    [[ -f "$path" ]] || continue
    [[ -w "$path" ]] || continue
    local cur
    cur="$(cat "$path")"
    if [[ "$cur" != "$MAX_KHZ" ]]; then
      echo "$MAX_KHZ" >"$path"
      changed=1
    fi
    log "$(dirname "$path") scaling_max_freq=$(cat "$path") (target ${MAX_KHZ} kHz / ${MAX_MHZ} MHz)"
  done

  if [[ "$changed" -eq 1 ]]; then
    log "max frequency cap applied (${MAX_MHZ} MHz)"
  else
    log "max frequency already at or below ${MAX_MHZ} MHz"
  fi
  return 0
}

deadline=$((SECONDS + MAX_WAIT_SEC))
while (( SECONDS < deadline )); do
  if ls /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq \
      /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq &>/dev/null; then
    apply_cap
    exit 0
  fi
  sleep "$INTERVAL_SEC"
done

log "ERROR: cpufreq scaling_max_freq sysfs not ready after ${MAX_WAIT_SEC}s" >&2
exit 1
