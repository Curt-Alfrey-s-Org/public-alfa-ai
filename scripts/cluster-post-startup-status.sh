#!/usr/bin/env bash
# Post-startup cluster status — containers, GPU, brain/RPC health, anti-bloat.
#
# Usage (from repo root):
#   HOST_PROFILE=hub-111 bash scripts/cluster-post-startup-status.sh
#   HOST_PROFILE=operator-93 bash scripts/cluster-post-startup-status.sh
#
# Profiles: hub-111 | apps-105 | operator-93 | gaming-worker-c-59 | gaming-worker-a-219 |
#           gaming-worker-b-249 | ai-148
#
# Env:
#   DOCKER_CMD     — override auto-detect (e.g. "sudo docker")
#   BRAIN_URL      — default http://hub
#   LOG_FILE       — when set, all output is tee'd by the caller wrapper
set -uo pipefail

HOST_PROFILE="${HOST_PROFILE:-}"
BRAIN_URL="${BRAIN_URL:-http://hub}"
LITELLM_URL="${LITELLM_URL:-http://hub}"

failures=0
warnings=0

log() { printf '%s\n' "$*"; }
section() { log ""; log "=== $* ==="; }
ok() { log "OK: $*"; }
warn() { log "WARN: $*"; warnings=$((warnings + 1)); }
fail() { log "FAIL: $*"; failures=$((failures + 1)); }

http_probe() {
  local label=$1 url=$2
  if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
    ok "$label $url"
    return 0
  fi
  fail "$label $url"
  return 1
}

tcp_listen() {
  local label=$1 host=$2 port=$3
  if timeout 2 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
    ok "TCP $label ${host}:${port}"
    return 0
  fi
  fail "TCP $label ${host}:${port}"
  return 1
}

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
    echo ""
  fi
}

load_profile() {
  case "$HOST_PROFILE" in
    hub-111)
      DOCKER_CMD="${DOCKER_CMD:-sudo docker}"
      LAN_IP="hub"
      RPC_PORT="31360"
      CHECK_BRAIN_STACK=1
      CHECK_DAEMON_JSON=1
      CHECK_PRUNE_CRON=1
      ;;
    apps-105)
      DOCKER_CMD="${DOCKER_CMD:-docker}"
      LAN_IP="apps"
      CHECK_BRAIN_REMOTE=1
      CHECK_EDGE_ADMIN=1
      CHECK_DAEMON_JSON=1
      CHECK_PRUNE_CRON=1
      ;;
    operator-93)
      DOCKER_CMD="${DOCKER_CMD:-docker}"
      LAN_IP="orchestrator"
      RPC_PORT="31350"
      CHECK_BRAIN_REMOTE=1
      ;;
    gaming-worker-c-59|gaming-worker-a-219|gaming-worker-b-249|ai-148)
      DOCKER_CMD="${DOCKER_CMD:-docker}"
      case "$HOST_PROFILE" in
        gaming-worker-c-59)    LAN_IP="orchestrator";  RPC_PORT="31351" ;;
        gaming-worker-a-219) LAN_IP="orchestrator"; RPC_PORT="31352" ;;
        gaming-worker-b-249)     LAN_IP="orchestrator"; RPC_PORT="31358" ;;
        ai-148)        LAN_IP="orchestrator"; RPC_PORT="" ;;
      esac
      CHECK_BRAIN_REMOTE=1
      ;;
    *)
      fail "Unknown HOST_PROFILE='$HOST_PROFILE' (set hub-111|apps-105|operator-93|gaming-worker-c-59|gaming-worker-a-219|gaming-worker-b-249|ai-148)"
      return 1
      ;;
  esac
}

section "Cluster post-startup status"
log "Timestamp: $(date -Iseconds)"
log "Host: $(hostname -f 2>/dev/null || hostname)"
log "Profile: ${HOST_PROFILE:-<unset>}"
log "Uptime: $(uptime 2>/dev/null || true)"

if [[ -z "$HOST_PROFILE" ]]; then
  fail "HOST_PROFILE is required"
  exit 1
fi
load_profile || exit 1

DOCKER="$(pick_docker)"
if [[ -z "$DOCKER" ]]; then
  fail "docker not available (tried docker and sudo docker)"
else
  ok "Docker: $DOCKER"
  # shellcheck disable=SC2206
  read -r -a DOCKER_ARR <<< "$DOCKER"
fi

section "Docker containers"
if [[ -n "$DOCKER" ]]; then
  "${DOCKER_ARR[@]}" ps -a --format 'table {{.Names}}\t{{.Status}}' 2>&1 || fail "docker ps failed"
  log ""
  log "Disk usage:"
  "${DOCKER_ARR[@]}" system df 2>&1 || warn "docker system df failed"
fi

section "Restart policies (alfa / llama.cpp)"
CONTAINER_RE='^(alfa-|alfa-ai-|llamacpp-|worker-|alfa-dockge|alfa-registry|alfa-aria2)'
if [[ -n "$DOCKER" ]]; then
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    policy=$("${DOCKER_ARR[@]}" inspect "$name" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo unknown)
    if [[ "$policy" == "unless-stopped" || "$policy" == "always" ]]; then
      ok "$name restart=$policy"
    else
      warn "$name restart=$policy (expected unless-stopped or always)"
    fi
  done < <("${DOCKER_ARR[@]}" ps -a --format '{{.Names}}' 2>/dev/null | grep -E "$CONTAINER_RE" || true)
fi

section "GPU"
if command -v nvidia-smi &>/dev/null; then
  nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv,noheader 2>&1 || warn "nvidia-smi failed"
else
  warn "nvidia-smi not on PATH"
fi

section "HTTP health"
if [[ "${CHECK_BRAIN_STACK:-0}" == "1" ]]; then
  http_probe "Brain API" "${BRAIN_URL}/health"
  http_probe "LiteLLM liveliness" "${LITELLM_URL}/health/liveliness"
fi
if [[ "${CHECK_BRAIN_REMOTE:-0}" == "1" ]]; then
  http_probe "Brain API (LAN)" "${BRAIN_URL}/health"
fi
if [[ "${CHECK_EDGE_ADMIN:-0}" == "1" ]]; then
  http_probe "Edge admin /alfa-ai/login (:8420)" "http://127.0.0.1:8420/alfa-ai/login"
fi

if [[ -n "${RPC_PORT:-}" && -n "${LAN_IP:-}" ]]; then
  section "llama.cpp RPC port"
  if timeout 2 bash -c "echo >/dev/tcp/${LAN_IP}/${RPC_PORT}" 2>/dev/null; then
    ok "TCP RPC ${LAN_IP}:${RPC_PORT}"
  else
    warn "TCP RPC ${LAN_IP}:${RPC_PORT} not listening (run deploy-llamacpp-rpc for this host)"
  fi
fi

if [[ "${CHECK_DAEMON_JSON:-0}" == "1" && -f /etc/docker/daemon.json ]]; then
  section "Docker daemon.json (anti-bloat)"
  if grep -q 'max-size' /etc/docker/daemon.json 2>/dev/null; then
    ok "log rotation configured in /etc/docker/daemon.json"
    grep -E 'log-driver|max-size|max-file' /etc/docker/daemon.json || true
  else
    warn "no log max-size in /etc/docker/daemon.json"
  fi
fi

if [[ "${CHECK_PRUNE_CRON:-0}" == "1" ]]; then
  section "Scheduled docker prune"
  if [[ -f /etc/cron.d/alfa-docker-cleanup ]]; then
    ok "/etc/cron.d/alfa-docker-cleanup present"
    cat /etc/cron.d/alfa-docker-cleanup
  elif [[ -f /etc/cron.d/docker-cleanup ]]; then
    warn "legacy /etc/cron.d/docker-cleanup present; prefer alfa-docker-cleanup"
    cat /etc/cron.d/docker-cleanup
  elif crontab -l 2>/dev/null | grep -qiE 'prune|docker-host-cleanup'; then
    ok "user crontab has prune/cleanup entry"
  else
    warn "no docker prune cron found (see docs/operations/DOCKER_HOST_CLEANUP.md)"
  fi
fi

section "SUMMARY"
log "Profile: $HOST_PROFILE"
log "Failures: $failures"
log "Warnings: $warnings"
if [[ "$failures" -gt 0 ]]; then
  log "RESULT: FAIL"
  exit 1
fi
log "RESULT: OK (warnings=$warnings)"
exit 0
