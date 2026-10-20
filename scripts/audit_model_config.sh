#!/usr/bin/env bash
# Run model-config drift audit (see docs/MODEL_CONFIG_DRIFT_PREVENTION.md).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"
exec python3 "$SCRIPT_DIR/audit_model_config.py" "$@"
