#!/usr/bin/env bash
# After sudo cp/mv, hub root umask often leaves files 0640 (rw-r-----).
# Docker bind-mounts keep host mode bits
# (https://docs.docker.com/engine/storage/bind-mounts/).
# GNU chmod a+r / a+rX:
# https://man7.org/linux/man-pages/man1/chmod.1.html
#
# Usage:
#   bash deploy/cluster-members/_common/ensure-posix-other-read.sh PATH [PATH...]
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 PATH [PATH...]" >&2
  exit 2
fi

other_digit() {
  local perm
  perm="$(stat -c '%a' "$1")"
  printf '%s' "${perm: -1}"
}

assert_other_ok() {
  local path="$1"
  local digit
  digit="$(other_digit "$path")"
  if [[ -d "$path" ]]; then
    if (( (digit & 4) == 0 || (digit & 1) == 0 )); then
      echo "ERROR: $path is not other-searchable/readable (mode $(stat -c '%a' "$path") $(stat -c '%A %U:%G' "$path"))" >&2
      echo "  sudo chmod a+rX $path" >&2
      exit 1
    fi
  elif [[ -f "$path" ]]; then
    if (( (digit & 4) == 0 )); then
      echo "ERROR: $path is not other-readable (mode $(stat -c '%a' "$path") $(stat -c '%A %U:%G' "$path"))" >&2
      echo "  sudo chmod a+r $path" >&2
      exit 1
    fi
  else
    echo "ERROR: missing $path" >&2
    exit 1
  fi
}

for path in "$@"; do
  if [[ -d "$path" ]]; then
    chmod a+rX "$path"
  elif [[ -f "$path" ]]; then
    chmod a+r "$path"
  else
    echo "ERROR: missing $path" >&2
    exit 1
  fi
  assert_other_ok "$path"
  echo "  other-read OK $(stat -c '%A %n' "$path")"
done
