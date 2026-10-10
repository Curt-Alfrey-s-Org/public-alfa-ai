#!/usr/bin/env bash
# ALFa AI — rollout preflight: health curls + optional production strict checks.
# Usage: ./scripts/alfa_ai_rollout_preflight.sh [path/to/deploy/.env] [--strict]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/deploy/.env"
STRICT=0

for arg in "$@"; do
  if [[ "$arg" == "--strict" ]]; then
    STRICT=1
  elif [[ "$arg" != -* ]]; then
    ENV_FILE="$arg"
  fi
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE"
  echo "Create it from deploy/.env first (gitignored on each host)."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

API_PORT="${ALFA_AI_API_HOST_PORT:-8412}"
LITELLM_PORT="${ALFA_AI_LITELLM_HOST_PORT:-8413}"
DEV_LITELLM_KEY="change-me"

echo "ALFa AI rollout preflight"
echo "  env file: $ENV_FILE"
echo "  API port:   $API_PORT"
echo "  LiteLLM port: $LITELLM_PORT"

if [[ "$STRICT" -eq 1 ]]; then
  echo "  mode: strict (production checks)"
  if [[ "${LITELLM_MASTER_KEY:-}" == "$DEV_LITELLM_KEY" ]] || [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
    echo "ERROR: Set LITELLM_MASTER_KEY to a non-default secret in production (--strict)."
    exit 1
  fi
  if [[ "${ALFA_AI_REQUIRE_API_AUTH:-false}" != "true" ]]; then
    echo "ERROR: Set ALFA_AI_REQUIRE_API_AUTH=true for production (--strict)."
    exit 1
  fi
  if [[ -z "${ALFA_AI_API_TOKEN:-}" ]]; then
    echo "ERROR: Set ALFA_AI_API_TOKEN in production (--strict)."
    exit 1
  fi
else
  echo "  mode: standard (add --strict before production cutover)"
fi

fail=0
check_http() {
  local name="$1" url="$2"
  if curl -fsS --max-time 15 "$url" >/dev/null; then
    echo "OK  $name ($url)"
  else
    echo "FAIL $name ($url) — is the stack up?"
    fail=1
  fi
}

check_litellm() {
  local base="http://127.0.0.1:${LITELLM_PORT}"
  if curl -fsS --max-time 15 "${base}/health/liveliness" >/dev/null 2>&1; then
    echo "OK  LiteLLM liveliness (${base}/health/liveliness)"
    return 0
  fi
  local key="${LITELLM_MASTER_KEY:-}"
  if [[ -n "$key" ]] && curl -fsS --max-time 15 -H "Authorization: Bearer ${key}" "${base}/health" >/dev/null 2>&1; then
    echo "OK  LiteLLM health (${base}/health with Authorization: Bearer …)"
    return 0
  fi
  echo "FAIL LiteLLM (${base}) — start: docker compose -f deploy/docker-compose.yml up -d alfa-ai-litellm"
  fail=1
}

check_http "ALFa API health" "http://127.0.0.1:${API_PORT}/health"
check_litellm

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "Preflight passed."
