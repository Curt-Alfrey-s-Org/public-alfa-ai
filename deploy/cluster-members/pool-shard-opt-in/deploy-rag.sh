#!/usr/bin/env bash
# VM100 — LEGACY embed + rerank on the GTX 1660 Super. RETIRED — see guard below.
set -euo pipefail

# RETIRED 2026-07-09: VM100 is inference-shard-only; production RAG runs on rag
# (deploy/cluster-members/rag-host). Running this would contend with the shard
# for the 1660S. Rollback only, and only with an explicit opt-in.
if [[ "${ALLOW_LEGACY_VM100_RAG:-0}" != "1" ]]; then
  echo "ERROR: RAG on pool-opt-in is retired (VM100 is inference-shard-only; RAG is on rag)." >&2
  echo "  Production: bash deploy/cluster-members/rag-host/deploy-rag-cpu.sh (on rag)" >&2
  echo "  Rollback only: ALLOW_LEGACY_VM100_RAG=1 bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== VM100 LEGACY RAG (embed :11435 + rerank :8360 on 1660S, rollback mode) =="
bash "$SCRIPT_DIR/deploy-embed.sh"
bash "$SCRIPT_DIR/deploy-rerank.sh"
echo "LEGACY RAG OK on pool-opt-in (rollback mode). Production RAG is rag (EMBED_BASE_URL=http://orchestrator RERANK_BASE_URL=http://orchestrator)."