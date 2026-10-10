#!/usr/bin/env bash
# hub Ryzen 7900X thermal policy: turbo off + fixed MHz ceiling (default 4.6 GHz).
#
# Same sysfs write pattern as cap-cpu-max-freq.sh / hub-build-thermal-profile.sh
# (policy* then cpu* scaling_max_freq). Must run as root:
#   sudo bash deploy/cluster-members/hub/disable-cpu-boost.sh
#
# Env:
#   ALFA_CPU_MAX_FREQ_MHZ   default 4600 (4600000 kHz)
set -euo pipefail

LOG_TAG="alfa-disable-cpu-boost"
BOOST_PATH="/sys/devices/system/cpu/cpufreq/boost"
CPB_PATH="/sys/devices/system/cpu/amd_pstate/cpb_boost"
MAX_MHZ="${ALFA_CPU_MAX_FREQ_MHZ:-4600}"
MAX_KHZ=$((MAX_MHZ * 1000))
MAX_WAIT_SEC="${ALFA_CPU_BOOST_WAIT_SEC:-120}"
INTERVAL_SEC=2

log() {
  echo "[$LOG_TAG] $*"
}

if [[ "$(id -u)" -ne 0 ]]; then
  log "ERROR: run as root: sudo bash $0" >&2
  exit 1
fi

disable_boost_nodes() {
  if [[ -w "$BOOST_PATH" ]]; then
    echo 0 >"$BOOST_PATH"
    log "cpufreq boost=$(cat "$BOOST_PATH")"
  fi

  if [[ -w "$CPB_PATH" ]]; then
    local cpb_current
    cpb_current="$(cat "$CPB_PATH")"
    if [[ "$cpb_current" != "0" && "$cpb_current" != "disabled" ]]; then
      if grep -q '^enabled$' <<<"$cpb_current" || grep -q '^disabled$' <<<"$cpb_current"; then
        echo disabled >"$CPB_PATH"
      else
        echo 0 >"$CPB_PATH"
      fi
    fi
    log "amd_pstate cpb_boost=$(cat "$CPB_PATH")"
  fi
}

apply_max_freq_cap() {
  local path dir cur hw target changed=0

  for path in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq \
              /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
    [[ -f "$path" ]] || continue
    dir="$(dirname "$path")"
    cur="$(cat "$path")"
    hw="$(cat "$dir/scaling_hw_max_freq" 2>/dev/null || echo "$cur")"
    target="$MAX_KHZ"
    if [[ "$hw" -lt "$target" ]]; then
      target="$hw"
    fi
    if [[ "$cur" != "$target" ]]; then
      echo "$target" >"$path"
      changed=1
    fi
    log "$(basename "$dir") scaling_max_freq=$(cat "$path") kHz (target ${MAX_MHZ} MHz)"
  done

  if [[ "$changed" -eq 1 ]]; then
    log "max frequency cap applied (${MAX_MHZ} MHz)"
  else
    log "max frequency already at ${MAX_MHZ} MHz on all nodes"
  fi
}

verify_policy() {
  local policy="/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq"
  local hw target="$MAX_KHZ" cur

  [[ -f "$policy" ]] || return 0
  hw="$(cat "$(dirname "$policy")/scaling_hw_max_freq" 2>/dev/null || echo "$target")"
  if [[ "$hw" -lt "$target" ]]; then
    target="$hw"
  fi
  cur="$(cat "$policy")"
  if [[ "$cur" != "$target" ]]; then
    log "ERROR: policy0 scaling_max_freq=${cur} kHz, expected ${target} kHz" >&2
    return 1
  fi
  if [[ -r "$BOOST_PATH" ]] && [[ "$(cat "$BOOST_PATH")" != "0" ]]; then
    log "ERROR: cpufreq boost=$(cat "$BOOST_PATH"), expected 0" >&2
    return 1
  fi
  return 0
}

apply_policy() {
  disable_boost_nodes
  apply_max_freq_cap
  verify_policy
}

deadline=$((SECONDS + MAX_WAIT_SEC))
while (( SECONDS < deadline )); do
  if ls /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq \
      /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq &>/dev/null; then
    apply_policy
    log "thermal policy OK: boost off, ${MAX_MHZ} MHz cap"
    exit 0
  fi
  sleep "$INTERVAL_SEC"
done

log "ERROR: cpufreq scaling_max_freq sysfs not ready after ${MAX_WAIT_SEC}s" >&2
exit 1
