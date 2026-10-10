#!/usr/bin/env bash
# hub hub — pull GGUF into HUB with env from aria2-env.sh (local RPC + paths).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aria2-env.sh
source "$SCRIPT_DIR/aria2-env.sh"
exec sudo -E bash "$ALFA_AI_REPO/scripts/hub_hub_models.sh" pull gguf "$@"
