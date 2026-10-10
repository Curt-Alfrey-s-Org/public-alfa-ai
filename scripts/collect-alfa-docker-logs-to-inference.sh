#!/usr/bin/env bash
# Dump alfa-ai / llama.cpp RPC / cluster-related container logs and optionally SCP to inference hub.
#
# Usage:
#   bash scripts/collect-alfa-docker-logs-to-148.sh
#   SCP_TO_BUILD_HOST=1 bash scripts/collect-alfa-docker-logs-to-148.sh
#
# Env:
#   SSH_HOST  — default operator@orchestrator
#   REMOTE_DIR — default /home/operator/alfa-ai/logs/cluster-docker
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_TAIL="${LOG_TAIL:-10000}"
TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
LOG_DIR="${REPO_ROOT}/logs/cluster-docker"
LOG_FILE="${LOG_DIR}/alfa-docker-${HOST}-${TS}.log"
mkdir -p "$LOG_DIR"

pick_docker() {
  if [[ -n "${DOCKER_CMD:-}" ]]; then
    echo "$DOCKER_CMD"
    return
  fi
  if docker info &>/dev/null; then
    echo docker
  elif sudo docker info &>/dev/null; then
    echo "sudo docker"
  else
    echo "ERROR: cannot run docker (tried docker and sudo docker)." >&2
    exit 1
  fi
}

DOCKER="$(pick_docker)"
# shellcheck disable=SC2206
read -r -a DOCKER_ARR <<< "$DOCKER"

CONTAINER_RE='^(alfa-|alfa-ai-|llamacpp-|worker-|dockge-agent|alfa-registry|alfa-aria2|alfa-verdaccio|alfa-ollama|alfa-dockge)'

echo "Repo root:  $REPO_ROOT"
echo "Docker:     $DOCKER"
echo "Log file:   $LOG_FILE"
echo ""

mapfile -t NAMES < <("${DOCKER_ARR[@]}" ps -a --format '{{.Names}}' 2>/dev/null | grep -E "$CONTAINER_RE" || true)

{
  echo "# alfa-ai cluster docker logs"
  echo "# host: $(hostname -f 2>/dev/null || hostname)"
  echo "# date: $(date -Iseconds)"
  echo "# docker: $DOCKER"
  echo "# containers matched: ${#NAMES[@]}"
  echo ""
} > "$LOG_FILE"

if [[ ${#NAMES[@]} -eq 0 ]]; then
  echo "WARN: no containers matched $CONTAINER_RE" >&2
  "${DOCKER_ARR[@]}" ps -a --format '  {{.Names}} ({{.Status}})' 2>&1 | head -40 >&2 || true
  echo "" >> "$LOG_FILE"
  echo "(no matching containers)" >> "$LOG_FILE"
else
  for c in "${NAMES[@]}"; do
    echo "  -> $c"
    {
      echo "======== ${c} ========"
      "${DOCKER_ARR[@]}" logs --tail "$LOG_TAIL" "$c" 2>&1 || echo "(docker logs failed for ${c})"
      echo
    } >> "$LOG_FILE"
  done
fi

BYTES=$(wc -c < "$LOG_FILE" | tr -d ' ')
echo ""
echo "Wrote ${BYTES} bytes -> $LOG_FILE"

if [[ "${SCP_TO_BUILD_HOST:-0}" == "1" ]]; then
  SSH_HOST="${SSH_HOST:-operator@orchestrator}"
  REMOTE_DIR="${REMOTE_DIR:-/home/operator/alfa-ai/logs/cluster-docker}"
  if [[ "$(cd "$(dirname "$LOG_FILE")" && pwd -P)" == "$(cd "$REMOTE_DIR" 2>/dev/null && pwd -P)" ]]; then
    echo "==> SCP skipped — log already under ${REMOTE_DIR}/"
  else
    echo "==> SCP_TO_BUILD_HOST=1 — copying to ${SSH_HOST}:${REMOTE_DIR}/"
    if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
         "$SSH_HOST" "mkdir -p '${REMOTE_DIR}'" \
      && scp -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new \
         "$LOG_FILE" "${SSH_HOST}:${REMOTE_DIR}/"; then
      echo "==> Copied: ${REMOTE_DIR}/$(basename "$LOG_FILE")"
    else
      echo "WARN: ssh/scp failed. Run deploy/cluster-members/_common/ensure-ssh-to-148.ps1 on Windows" >&2
    fi
  fi
fi