#!/usr/bin/env bash
# Install inference keep-warm cron on hub (brain host, localhost LiteLLM).
#
# Replaces the legacy apps cron (avoids LAN hop to :8413). Shard verify still runs
# from inference during orchestrator start; cron warm uses local LiteLLM only.
#
# Usage (on hub as operator):
#   bash deploy/cluster-members/hub/install-inference-keep-warm-cron.sh
#
# Env:
#   ALFA_AI_REPO  default /mnt/hub/alfa-ai/repo/alfa-ai
set -euo pipefail

REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
LOG_DIR="${inference_WARM_LOG_DIR:-$REPO_DIR/logs}"
MARKER="# alfa-ai inference keep-warm (hub brain)"
WARM_ENV="inference_WARM_LITELLM_BASE=http://127.0.0.1:8413 inference_WARM_CONTRACTS_BOT_URL=http://apps ALFA_BRAIN_ENV=$REPO_DIR/deploy/.env"
CRON_LINE="*/15 * * * * cd $REPO_DIR && $WARM_ENV bash scripts/keep-inference-warm.sh >> $LOG_DIR/inference-keep-warm.log 2>&1"

if [[ ! -f "$REPO_DIR/scripts/keep-inference-warm.sh" ]]; then
  echo "ERROR: missing $REPO_DIR/scripts/keep-inference-warm.sh" >&2
  exit 1
fi
if [[ ! -f "$REPO_DIR/deploy/.env" ]]; then
  echo "ERROR: missing $REPO_DIR/deploy/.env (brain secrets)" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
chmod +x "$REPO_DIR/scripts/keep-inference-warm.sh"

TMP="$(mktemp)"
crontab -l 2>/dev/null | grep -Fv "$MARKER" | grep -Fv "keep-inference-warm.sh" >"$TMP" || true
echo "$CRON_LINE $MARKER" >>"$TMP"
crontab "$TMP"
rm -f "$TMP"

echo "Installed inference keep-warm cron on hub (every 15 min, LiteLLM 127.0.0.1:8413)."
echo "Log: $LOG_DIR/inference-keep-warm.log"
echo "Remove legacy apps cron: bash scripts/install-inference-keep-warm-cron.sh --uninstall-only"
crontab -l | grep keep-inference-warm || true