#!/usr/bin/env bash
# hub hub — hub model status (sources aria2-env.sh for HUB_ROOT consistency).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=aria2-env.sh
source "$SCRIPT_DIR/aria2-env.sh"
exec sudo -E bash "$ALFA_AI_REPO/scripts/hub_hub_models.sh" status "$@"
