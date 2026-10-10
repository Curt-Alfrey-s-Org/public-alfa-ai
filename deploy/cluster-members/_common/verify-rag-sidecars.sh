#!/usr/bin/env bash
# TCP + HTTP preflight: canonical RAG sidecars must be reachable.
#
# Usage:
#   bash deploy/cluster-members/_common/verify-rag-sidecars.sh
#   RAG_REQUIRE_RERANK=1 bash ...   # default: embed + rerank both required
#   RAG_REQUIRE_RERANK=0 bash ...   # maintenance: embed-only (not for production start)
#   RAG_VERIFY_RETRIES=36 bash ...  # retry embed up to ~3 min (ollama cold start)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAG_ENV_FILE="${RAG_SIDECARS_ENV:-$SCRIPT_DIR/rag-sidecars.env}"
# shellcheck source=rag-sidecars.env
source "$RAG_ENV_FILE"

fail=0
RETRIES="${RAG_VERIFY_RETRIES:-12}"
INTERVAL="${RAG_VERIFY_INTERVAL_SEC:-5}"

wait_tcp_retry() {
  local host="$1" port="$2" label="$3"
  local attempt=1
  while [[ "$attempt" -le "$RETRIES" ]]; do
    if nc -z -w 5 "$host" "$port" 2>/dev/null; then
      echo "  OK $label $host:$port (attempt $attempt)"
      return 0
    fi
    if [[ "$attempt" -lt "$RETRIES" ]]; then
      echo "  WAIT $label $host:$port (attempt $attempt/$RETRIES)" >&2
      sleep "$INTERVAL"
    fi
    attempt=$((attempt + 1))
  done
  echo "  FAIL $label $host:$port not reachable after $RETRIES attempts" >&2
  return 1
}

http_ok_retry() {
  local url="$1" label="$2"
  local attempt=1
  while [[ "$attempt" -le "$RETRIES" ]]; do
    if curl -fsS --max-time 15 "$url" >/dev/null 2>&1; then
      echo "  OK $label $url (attempt $attempt)"
      return 0
    fi
    if [[ "$attempt" -lt "$RETRIES" ]]; then
      echo "  WAIT $label $url (attempt $attempt/$RETRIES)" >&2
      sleep "$INTERVAL"
    fi
    attempt=$((attempt + 1))
  done
  echo "  FAIL $label $url after $RETRIES attempts" >&2
  return 1
}

echo "== verify RAG sidecars (canonical) =="
if ! wait_tcp_retry "$EMBED_HOST" "$EMBED_PORT" "embed"; then
  fail=1
fi
if ! http_ok_retry "http://${EMBED_HOST}:${EMBED_PORT}${EMBED_HEALTH_PATH}" "embed HTTP"; then
  fail=1
fi

if [[ "${RAG_REQUIRE_RERANK:-0}" == "1" ]]; then
  if ! wait_tcp_retry "$RERANK_HOST" "$RERANK_PORT" "rerank"; then
    fail=1
  fi
  if ! http_ok_retry "http://${RERANK_HOST}:${RERANK_PORT}${RERANK_HEALTH_PATH}" "rerank HTTP"; then
    fail=1
  fi
else
  if nc -z -w 3 "$RERANK_HOST" "$RERANK_PORT" 2>/dev/null; then
    echo "  OK rerank $RERANK_HOST:$RERANK_PORT (optional, up)"
  else
    echo "  SKIP rerank $RERANK_HOST:$RERANK_PORT (optional, not required)"
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "ERROR: RAG sidecar verify failed" >&2
  exit 1
fi
if [[ "${RAG_REQUIRE_RERANK:-0}" == "1" ]]; then
  echo "RAG sidecars reachable (embed + rerank on ${EMBED_HOST}:${EMBED_PORT} + ${RERANK_HOST}:${RERANK_PORT})"
else
  echo "RAG embed reachable on ${EMBED_HOST}:${EMBED_PORT} (rerank optional)"
fi