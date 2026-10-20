#!/usr/bin/env bash
# Deprecated wrapper — use remove-ollama-qwen3-4b-8b.sh (includes 30B MoE tag).
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
exec bash "$REPO_DIR/deploy/cluster-members/_common/remove-ollama-qwen3-4b-8b.sh" "$@"
