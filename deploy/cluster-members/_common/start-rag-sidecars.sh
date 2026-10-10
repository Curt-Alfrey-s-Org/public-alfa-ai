#!/usr/bin/env bash
# Start canonical RAG sidecars on rag (CPU embed + CPU rerank).
#
# Usage:
#   HOST_LABEL=110 bash deploy/cluster-members/_common/start-rag-sidecars.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
RAG_ENV_FILE="${RAG_SIDECARS_ENV:-$SCRIPT_DIR/rag-sidecars.env}"
# shellcheck source=rag-sidecars.env
source "$RAG_ENV_FILE"
LABEL="${HOST_LABEL:-$(hostname -s)}"

echo "== start-rag-sidecars: $LABEL =="

case "$LABEL" in
  110|vm110|alfa-ai-110)
    bash "$REPO_DIR/deploy/cluster-members/rag-host/deploy-rag-cpu.sh"
    ;;
  100|vm100|alfa-ai-100)
    echo "ERROR: RAG retired from pool-opt-in (now inference shard-only) — use HOST_LABEL=110" >&2
    echo "  See docs/RAG_148_TO_110_MIGRATION.md" >&2
    exit 1
    ;;
  148|ai-148)
    echo "ERROR: RAG retired from inference (now inference shard-only) — use HOST_LABEL=110" >&2
    echo "  See docs/RAG_148_TO_110_MIGRATION.md" >&2
    exit 1
    ;;
  *)
    echo "ERROR: canonical RAG runs on rag (production); got $LABEL" >&2
    exit 1
    ;;
esac

echo "start-rag-sidecars done on $LABEL"
