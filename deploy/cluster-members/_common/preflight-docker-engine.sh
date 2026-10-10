#!/usr/bin/env bash
# Preflight: Docker CLI installed, daemon running, server version reported.
# Tries "systemctl start docker" once when the daemon is down (Linux hosts).
#
# Usage:
#   bash deploy/cluster-members/_common/preflight-docker-engine.sh
#   ALFA_DOCKER_MIN_VERSION=28.0 bash .../preflight-docker-engine.sh
#
# Official: https://docs.docker.com/engine/install/ (daemon must answer docker info)
set -euo pipefail

LABEL="${HOST_LABEL:-$(hostname -s)}"
MIN_VERSION="${ALFA_DOCKER_MIN_VERSION:-28.0}"

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    echo docker
    return 0
  fi
  if sudo docker info >/dev/null 2>&1; then
    echo "sudo docker"
    return 0
  fi
  return 1
}

start_daemon_if_linux() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  if systemctl is-active docker >/dev/null 2>&1; then
    return 0
  fi
  echo "  docker daemon inactive; trying: sudo systemctl start docker" >&2
  if sudo systemctl start docker 2>/dev/null; then
    sleep 2
  fi
}

version_ge() {
  local a="${1#v}" b="${2#v}"
  if [[ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -1)" == "$b" ]]; then
    return 0
  fi
  return 1
}

echo "== preflight-docker-engine: $LABEL =="

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker CLI not installed on $LABEL" >&2
  echo "  Install Docker Engine per https://docs.docker.com/engine/install/" >&2
  exit 1
fi

start_daemon_if_linux

DC=""
if ! DC="$(docker_cmd)"; then
  echo "ERROR: Docker daemon not reachable on $LABEL" >&2
  echo "  Run: sudo systemctl start docker   (or start Docker Desktop / WSL engine)" >&2
  echo "  Then: sudo docker info" >&2
  exit 1
fi

SERVER="$($DC version --format '{{.Server.Version}}' 2>/dev/null || true)"
CLIENT="$($DC version --format '{{.Client.Version}}' 2>/dev/null || true)"
if [[ -z "$SERVER" ]]; then
  echo "ERROR: docker info succeeded but Server version empty on $LABEL" >&2
  exit 1
fi

echo "  Client=$CLIENT Server=$SERVER ($DC)"

if ! version_ge "$SERVER" "$MIN_VERSION"; then
  echo "WARN: Docker Server $SERVER < ALFA_DOCKER_MIN_VERSION=$MIN_VERSION on $LABEL" >&2
  echo "  Align cluster engines per docs/GREV27_27B_OPERATOR.md (hub hub target: 28.x+)." >&2
fi

echo "preflight-docker-engine OK on $LABEL"
