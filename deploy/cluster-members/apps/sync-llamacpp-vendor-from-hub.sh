#!/usr/bin/env bash
# Linux (apps): copy hub llama.cpp.tar.gz into vendor/ (same tarball all hosts use).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
exec bash "$SCRIPT_DIR/../_common/sync-llamacpp-vendor-from-hub.sh" "$REPO_DIR"
