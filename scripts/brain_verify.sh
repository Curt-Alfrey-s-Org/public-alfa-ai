#!/usr/bin/env bash
# Post-start verification for the ALFa AI brain stack.
#
# Local mode (brain host hub): docker container health + localhost HTTP probes.
# Remote mode (cluster hub inference, etc.): HTTP probes against ALFA_BRAIN_URL plus
# optional edge proxy on this host. Auto-detects mode unless BRAIN_VERIFY_MODE
# is set to local or remote.
#
# Usage:
#   bash scripts/brain_verify.sh
#   bash scripts/brain_verify.sh --strict          # fail on optional warnings too
#   bash scripts/brain_verify.sh --skip-grev27     # brain-only (no 27B pool check)
#
# Env:
#   ALFA_BRAIN_URL=http://hub   (remote mode; read from deploy/.env.apps)
#   BRAIN_VERIFY_MODE=auto|local|remote
#
# Called by: scripts/start.sh, scripts/full_deploy.sh, scripts/brain_redeploy_api.sh,
#            deploy/cluster-members/hub/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_alfa_compose_env.sh"

STRICT=0
SKIP_GREV27=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --skip-grev27) SKIP_GREV27=1 ;;
    -h|--help)
      sed -n '1,20p' "$0" | tail -n +2
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

COMMON_WAIT="$ALFA_AI_APP_ROOT/deploy/cluster-members/_common"
_getp() {
  grep -E "^$1=" "$2" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

API_PORT="${ALFA_AI_API_HOST_PORT:-8412}"
OP_PORT="${ALFA_AI_OPERATOR_CONSOLE_HOST_PORT:-8420}"
LITELLM_PORT="${ALFA_AI_LITELLM_HOST_PORT:-8413}"
NGINX_PORT="${ALFA_AI_NGINX_HOST_PORT:-8090}"
CODE27_URL="${LLAMACPP_CODE27_URL:-http://127.0.0.1:31360/v1}"
BRAIN_BASE_URL="${ALFA_BRAIN_URL:-http://hub}"

for envfile in "$ALFA_AI_DEPLOY_DIR/.env.apps" "$ALFA_AI_ENV_FILE"; do
  if [[ -f "$envfile" ]]; then
    _p=$(_getp ALFA_AI_API_HOST_PORT "$envfile") && [[ -n "$_p" ]] && API_PORT="$_p"
    _p=$(_getp ALFA_AI_OPERATOR_CONSOLE_HOST_PORT "$envfile") && [[ -n "$_p" ]] && OP_PORT="$_p"
    _p=$(_getp ALFA_AI_LITELLM_HOST_PORT "$envfile") && [[ -n "$_p" ]] && LITELLM_PORT="$_p"
    _p=$(_getp ALFA_AI_NGINX_HOST_PORT "$envfile") && [[ -n "$_p" ]] && NGINX_PORT="$_p"
    _p=$(_getp LLAMACPP_CODE27_URL "$envfile") && [[ -n "$_p" ]] && CODE27_URL="$_p"
    _p=$(_getp ALFA_BRAIN_URL "$envfile") && [[ -n "$_p" ]] && BRAIN_BASE_URL="$_p"
  fi
done

BRAIN_BASE_URL="${BRAIN_BASE_URL%/}"
if [[ "$BRAIN_BASE_URL" =~ ^https?://([^:/]+)(:([0-9]+))?$ ]]; then
  BRAIN_HOST="${BASH_REMATCH[1]}"
  REMOTE_OP_PORT="${BASH_REMATCH[3]:-$OP_PORT}"
else
  BRAIN_HOST="hub"
  REMOTE_OP_PORT="$OP_PORT"
fi

GREV27_HEALTH="${CODE27_URL%/v1}/health"
# Coordinator uses host network on hub; host.docker.internal is for LiteLLM in bridge only.
GREV27_HEALTH="${GREV27_HEALTH//host.docker.internal/127.0.0.1}"
GREV27_EXPECT="http://127.0.0.1:31360/v1"
GREV27_LITELLM_BRIDGE="http://host.docker.internal:31360/v1"

fail=0
warn=0

note_ok() { echo "OK   $*"; }
note_fail() { echo "FAIL $*"; fail=1; }
note_warn() { echo "WARN $*"; warn=1; }

alfa_brain_stack_local() {
  # Dedicated protected stacks (VM100 / post-split hub): alfa-postgres + alfa-redis.
  # Legacy monolithic compose used alfa-ai-postgres / alfa-ai-redis.
  local names
  names="$("${ALFA_AI_DOCKER[@]}" ps --format '{{.Names}}' 2>/dev/null || true)"
  echo "$names" | grep -qx 'alfa-ai-litellm' || return 1
  echo "$names" | grep -qE '^(alfa-postgres|alfa-ai-postgres)$'
}

VERIFY_MODE="${BRAIN_VERIFY_MODE:-auto}"
if [[ "$VERIFY_MODE" == "auto" ]]; then
  if alfa_brain_stack_local; then
    VERIFY_MODE="local"
  else
    VERIFY_MODE="remote"
  fi
fi

echo "== brain_verify: mode =="
echo "brain_verify mode: $VERIFY_MODE (brain=$BRAIN_BASE_URL)"
echo

if [[ "$VERIFY_MODE" == "local" ]]; then
  echo "== brain_verify: containers =="
  _running_names="$("${ALFA_AI_DOCKER[@]}" ps --format '{{.Names}}' 2>/dev/null || true)"
  if echo "$_running_names" | grep -qx 'alfa-postgres'; then
    REQUIRED_CONTAINERS=(alfa-postgres alfa-redis alfa-ai-litellm alfa-ai-api alfa-ai-nginx)
  else
    REQUIRED_CONTAINERS=(alfa-ai-postgres alfa-ai-redis alfa-ai-litellm alfa-ai-api alfa-ai-nginx)
  fi
  for name in "${REQUIRED_CONTAINERS[@]}"; do
    if ! "${ALFA_AI_DOCKER[@]}" ps --format '{{.Names}}' | grep -qx "$name"; then
      note_fail "$name not running"
      continue
    fi
    h=$("${ALFA_AI_DOCKER[@]}" inspect "$name" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo none)
    if [[ "$h" == "healthy" || "$h" == "none" ]]; then
      note_ok "$name ($h)"
    else
      note_fail "$name health=$h"
    fi
  done
  echo

  LITELLM_URL="http://127.0.0.1:${LITELLM_PORT}/health/liveliness"
  API_HEALTH_URL="http://127.0.0.1:${API_PORT}/health"
  OP_HEALTH_URL="http://127.0.0.1:${OP_PORT}/health"
  LOGIN_URL="http://127.0.0.1:${OP_PORT}/alfa-ai/login"
  NGINX_HEALTH_URL="http://127.0.0.1:${NGINX_PORT}/health"
else
  echo "== brain_verify: containers (remote) =="
  note_ok "brain stack on $BRAIN_HOST (local docker checks skipped)"
  if "${ALFA_AI_DOCKER[@]}" ps --format '{{.Names}}' 2>/dev/null | grep -qx 'alfa-ai-api'; then
    img=$("${ALFA_AI_DOCKER[@]}" inspect alfa-ai-api --format='{{.Config.Image}}' 2>/dev/null || echo unknown)
    if [[ "$img" == *nginx* ]]; then
      h=$("${ALFA_AI_DOCKER[@]}" inspect alfa-ai-api --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo none)
      if [[ "$h" == "healthy" || "$h" == "none" ]]; then
        note_ok "alfa-ai-edge-api ($h)"
      else
        note_fail "alfa-ai-edge-api health=$h"
      fi
    else
      note_warn "alfa-ai-api running locally but not brain postgres (unexpected image: $img)"
    fi
  fi
  echo

  LITELLM_URL="http://${BRAIN_HOST}:${LITELLM_PORT}/health/liveliness"
  API_HEALTH_URL="http://${BRAIN_HOST}:${REMOTE_OP_PORT}/health"
  OP_HEALTH_URL="$API_HEALTH_URL"
  LOGIN_URL="http://${BRAIN_HOST}:${REMOTE_OP_PORT}/alfa-ai/login"
  NGINX_HEALTH_URL=""
fi

echo "== brain_verify: HTTP (wait helpers) =="
REMOTE_WAIT_SEC=60
if [[ "$VERIFY_MODE" == "local" && -x "$COMMON_WAIT/wait-litellm-liveliness.sh" ]]; then
  if bash "$COMMON_WAIT/wait-litellm-liveliness.sh" 120; then
    note_ok "LiteLLM liveliness :${LITELLM_PORT}"
  else
    note_fail "LiteLLM liveliness :${LITELLM_PORT}"
  fi
elif [[ -x "$COMMON_WAIT/wait-http.sh" ]]; then
  if bash "$COMMON_WAIT/wait-http.sh" "$LITELLM_URL" "$REMOTE_WAIT_SEC"; then
    note_ok "LiteLLM liveliness ${LITELLM_URL}"
  else
    note_fail "LiteLLM liveliness ${LITELLM_URL}"
  fi
else
  if curl -fsS --max-time 10 "$LITELLM_URL" >/dev/null; then
    note_ok "LiteLLM liveliness ${LITELLM_URL}"
  else
    note_fail "LiteLLM liveliness ${LITELLM_URL}"
  fi
fi

if [[ "$VERIFY_MODE" == "local" && -x "$COMMON_WAIT/wait-brain-health.sh" ]]; then
  if ALFA_AI_API_HOST_PORT="$API_PORT" bash "$COMMON_WAIT/wait-brain-health.sh" 120; then
    note_ok "API /health :${API_PORT}"
  else
    note_fail "API /health :${API_PORT}"
  fi
elif [[ -x "$COMMON_WAIT/wait-http.sh" ]]; then
  if bash "$COMMON_WAIT/wait-http.sh" "$API_HEALTH_URL" "$REMOTE_WAIT_SEC"; then
    note_ok "API /health ${API_HEALTH_URL}"
  else
    note_fail "API /health ${API_HEALTH_URL}"
  fi
else
  if curl -fsS --max-time 10 "$API_HEALTH_URL" >/dev/null; then
    note_ok "API /health ${API_HEALTH_URL}"
  else
    note_fail "API /health ${API_HEALTH_URL}"
  fi
fi

if curl -fsS --max-time 10 "$OP_HEALTH_URL" >/dev/null; then
  note_ok "operator console /health ${OP_HEALTH_URL}"
else
  note_fail "operator console /health ${OP_HEALTH_URL}"
fi

# SPA/index can be slow right after API recreate; wait then check title.
# wait-http: deploy/cluster-members/_common/wait-http.sh (curl poll).
LOGIN_WAIT_SEC="${LOGIN_WAIT_SEC:-120}"
LOGIN_CURL_MAX="${LOGIN_CURL_MAX:-20}"
if [[ -x "$COMMON_WAIT/wait-http.sh" ]]; then
  if bash "$COMMON_WAIT/wait-http.sh" "$LOGIN_URL" "$LOGIN_WAIT_SEC" 5 "$LOGIN_CURL_MAX" \
    && curl -fsS --max-time "$LOGIN_CURL_MAX" "$LOGIN_URL" | grep -q '<title>ALFa AI</title>'; then
    note_ok "operator console /alfa-ai/login ${LOGIN_URL}"
  else
    note_fail "operator console /alfa-ai/login ${LOGIN_URL}"
  fi
elif curl -fsS --max-time "$LOGIN_CURL_MAX" "$LOGIN_URL" | grep -q '<title>ALFa AI</title>'; then
  note_ok "operator console /alfa-ai/login ${LOGIN_URL}"
else
  note_fail "operator console /alfa-ai/login ${LOGIN_URL}"
fi

if [[ "$VERIFY_MODE" == "remote" ]]; then
  if "${ALFA_AI_DOCKER[@]}" ps --format '{{.Names}}' 2>/dev/null | grep -qx 'alfa-ai-api'; then
    EDGE_LOGIN="http://127.0.0.1:${OP_PORT}/alfa-ai/login"
    if curl -fsS --max-time 10 "$EDGE_LOGIN" | grep -q '<title>ALFa AI</title>'; then
      note_ok "local edge proxy /alfa-ai/login ${EDGE_LOGIN}"
    else
      note_fail "local edge proxy /alfa-ai/login ${EDGE_LOGIN}"
    fi
  fi
fi

if [[ -n "$NGINX_HEALTH_URL" ]]; then
  if curl -fsS --max-time 10 "$NGINX_HEALTH_URL" >/dev/null; then
    note_ok "nginx /health :${NGINX_PORT}"
  else
    note_warn "nginx /health :${NGINX_PORT}"
  fi
elif [[ "$VERIFY_MODE" == "remote" ]]; then
  note_ok "nginx /health skipped (loopback-only on brain host; run brain_verify on hub for nginx)"
fi
echo

if [[ "$SKIP_GREV27" -eq 0 ]]; then
  echo "== brain_verify: G-rev27 frontier-code (27B preferred) =="
  if [[ "$CODE27_URL" == "$GREV27_EXPECT" ]]; then
    note_ok "LLAMACPP_CODE27_URL -> localhost :31360"
  elif [[ "$CODE27_URL" == "$GREV27_LITELLM_BRIDGE" ]]; then
    note_ok "LLAMACPP_CODE27_URL -> host.docker.internal :31360 (LiteLLM bridge -> host-network coordinator)"
  else
    note_warn "LLAMACPP_CODE27_URL=$CODE27_URL (expected $GREV27_EXPECT or $GREV27_LITELLM_BRIDGE for active 27B pool)"
  fi
  if bash "$COMMON_WAIT/wait-llamacpp-coordinator-health.sh" "$GREV27_HEALTH" 900 10 2>/dev/null \
    && curl -fsS --max-time 5 "$GREV27_HEALTH" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    note_ok "27B CPU coordinator $GREV27_HEALTH"
  else
    note_fail "27B CPU coordinator $GREV27_HEALTH (switch-pool-27b on hub; coordinator :31360)"
  fi
  echo
fi

echo "== brain_verify: summary =="
if [[ "$fail" -ne 0 ]]; then
  echo "brain_verify FAILED ($fail hard error(s))"
  exit 1
fi
if [[ "$STRICT" -eq 1 && "$warn" -ne 0 ]]; then
  echo "brain_verify FAILED (--strict: $warn warning(s))"
  exit 1
fi
if [[ "$warn" -ne 0 ]]; then
  echo "brain_verify passed with $warn warning(s)"
else
  echo "brain_verify passed"
fi
exit 0
