#!/usr/bin/env bash
# Wrapper: pack llama.cpp source tarball onto the hub (run on hub as root/sudo).
# Delegates to repo scripts/pack-llamacpp-vendor-tarball-on-hub.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
exec sudo bash "$REPO_DIR/scripts/pack-llamacpp-vendor-tarball-on-hub.sh" "$@"
