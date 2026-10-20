#!/usr/bin/env bash
# Deprecated wrapper -- use deploy-llamacpp-rpc-shard.sh (Code27 apps :31354).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/deploy-llamacpp-rpc-shard.sh" "$@"
