#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
LOG_FILE="$LOG_DIR/aria2-bootstrap-${HOST}-${TS}.log"

echo "Running bootstrap with log capture..."
echo "Log file: $LOG_FILE"

set +e
bash "$SCRIPT_DIR/aria2-bootstrap.sh" 2>&1 | tee "$LOG_FILE"
STATUS=${PIPESTATUS[0]}
set -e

echo "LOG FILE: $LOG_FILE"
exit "$STATUS"
