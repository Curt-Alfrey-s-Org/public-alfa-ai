#!/usr/bin/env bash
# Post-stop: canonical RAG ports must be closed; legacy hosts warn-only (retired Jul 2026).
#
# Usage:
#   bash deploy/cluster-members/_common/verify-rag-sidecars-stopped.sh
#   RAG_REQUIRE_RERANK=0 bash ...   # maintenance: embed-only stop verify (non-production)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rag-sidecars.env
source "$SCRIPT_DIR/rag-sidecars.env"

fail=0
warn=0

must_be_closed() {
  local host="$1" port="$2" label="$3"
  if nc -z -w 3 "$host" "$port" 2>/dev/null; then
    echo "  FAIL $label $host:$port still listening" >&2
    fail=1
  else
    echo "  OK $label $host:$port closed"
  fi
}

warn_if_open() {
  local host="$1" port="$2" label="$3"
  if nc -z -w 3 "$host" "$port" 2>/dev/null; then
    echo "  WARN $label $host:$port still listening (legacy; canonical RAG is rag)" >&2
    warn=1
  else
    echo "  OK $label $host:$port closed"
  fi
}

echo "== verify RAG sidecars stopped =="
must_be_closed "$EMBED_HOST" "$EMBED_PORT" "embed"
if [[ "${RAG_REQUIRE_RERANK:-0}" == "1" ]]; then
  must_be_closed "$RERANK_HOST" "$RERANK_PORT" "rerank"
else
  warn_if_open "$RERANK_HOST" "$RERANK_PORT" "rerank (optional)"
fi

if [[ "${LEGACY_RAG_VERIFY_STRICT:-0}" == "1" ]]; then
  must_be_closed "$LEGACY_RERANK_111_HOST" "$LEGACY_RERANK_111_PORT" "legacy hub rerank"
  must_be_closed "$LEGACY_EMBED_111_HOST" "$LEGACY_EMBED_111_PORT" "legacy hub embed"
  must_be_closed "$LEGACY_EMBED_100_HOST" "$LEGACY_EMBED_100_PORT" "legacy pool-opt-in embed"
  must_be_closed "$LEGACY_RERANK_100_HOST" "$LEGACY_RERANK_100_PORT" "legacy pool-opt-in rerank"
  must_be_closed "${LEGACY_EMBED_148_HOST:-orchestrator}" "${LEGACY_EMBED_148_PORT:-11435}" "legacy inference embed"
  must_be_closed "${LEGACY_RERANK_148_CPU_HOST:-orchestrator}" "${LEGACY_RERANK_148_CPU_PORT:-8360}" "legacy inference rerank"
else
  warn_if_open "$LEGACY_RERANK_111_HOST" "$LEGACY_RERANK_111_PORT" "legacy hub rerank"
  warn_if_open "$LEGACY_EMBED_111_HOST" "$LEGACY_EMBED_111_PORT" "legacy hub embed"
  warn_if_open "$LEGACY_EMBED_100_HOST" "$LEGACY_EMBED_100_PORT" "legacy pool-opt-in embed"
  warn_if_open "$LEGACY_RERANK_100_HOST" "$LEGACY_RERANK_100_PORT" "legacy pool-opt-in rerank"
  warn_if_open "${LEGACY_EMBED_148_HOST:-orchestrator}" "${LEGACY_EMBED_148_PORT:-11435}" "legacy inference embed"
  warn_if_open "${LEGACY_RERANK_148_CPU_HOST:-orchestrator}" "${LEGACY_RERANK_148_CPU_PORT:-8360}" "legacy inference rerank"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "ERROR: RAG sidecar stop verify failed" >&2
  exit 1
fi
if [[ "$warn" -ne 0 ]]; then
  echo "WARN: legacy/optional RAG ports still open (non-blocking; canonical rag embed must be closed)" >&2
fi
echo "RAG sidecars stopped"