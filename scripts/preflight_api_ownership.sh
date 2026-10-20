#!/usr/bin/env bash
set -euo pipefail
# Enforce single owner for alfa-ai-api: systemd (host uvicorn) XOR Docker Compose.
# Audit CROSS-RULE-007 / deployment-process-ownership.mdc.
#
# Usage:
#   scripts/preflight_api_ownership.sh compose-will-manage-api
#       Exit 1 if systemd unit alfa-ai-api.service is active (would collide with
#       Compose-published ALFA_AI_API_HOST_PORT on the host).
#
#   scripts/preflight_api_ownership.sh systemd-will-manage-api
#       Exit 1 if Docker container alfa-ai-api exists and is running.
#
# Environment:
#   ALFA_AI_SKIP_API_OWNERSHIP_CHECK=1   Bypass checks (emergency / automation only).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: $0 compose-will-manage-api | systemd-will-manage-api" >&2
  echo "See docs/DEPLOYMENT_BASELINE.md — Runtime ownership." >&2
  exit 2
}

if [[ -n "${ALFA_AI_SKIP_API_OWNERSHIP_CHECK:-}" ]]; then
  echo "WARN: skipping API ownership preflight (ALFA_AI_SKIP_API_OWNERSHIP_CHECK=1)" >&2
  exit 0
fi

MODE="${1:-}"
[[ -n "$MODE" ]] || usage

case "$MODE" in
  compose-will-manage-api)
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl cat alfa-ai-api.service &>/dev/null; then
        if systemctl is-active --quiet alfa-ai-api.service 2>/dev/null; then
          echo "ERROR: systemd unit alfa-ai-api.service is ACTIVE on this host." >&2
          echo "Docker Compose cannot publish alfa-ai-api on the same loopback port (Twelve-Factor / single owner)." >&2
          echo "Fix (Compose-owned brain — canonical on hub):" >&2
          echo "  sudo systemctl stop alfa-ai-api.service" >&2
          echo "  sudo systemctl disable alfa-ai-api.service" >&2
          echo "Then re-run deploy. See docs/DEPLOYMENT_BASELINE.md § Runtime ownership." >&2
          echo "Emergency bypass: ALFA_AI_SKIP_API_OWNERSHIP_CHECK=1" >&2
          exit 1
        fi
      fi
    fi
    ;;
  systemd-will-manage-api)
    if command -v docker >/dev/null 2>&1; then
      if docker inspect -f '{{.State.Running}}' alfa-ai-api 2>/dev/null | grep -qx true; then
        echo "ERROR: Docker container alfa-ai-api is RUNNING." >&2
        echo "Stop/remove it before enabling host systemd uvicorn:" >&2
        echo "  cd $ROOT/deploy && docker compose --env-file .env -f docker-compose.yml stop alfa-ai-api" >&2
        echo "See docs/DEPLOYMENT_BASELINE.md § Hybrid." >&2
        exit 1
      fi
    fi
    ;;
  *)
    usage
    ;;
esac

exit 0
