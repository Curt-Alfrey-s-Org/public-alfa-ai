#!/usr/bin/env bash
# inference keep-warm cron installer.
#
# Canonical host: hub brain — run:
#   bash deploy/cluster-members/hub/install-inference-keep-warm-cron.sh
#
# This wrapper on apps (or any host) only removes legacy apps cron entries.
#
# Usage:
#   bash scripts/install-inference-keep-warm-cron.sh --uninstall-only   # drop apps cron
#   bash scripts/install-inference-keep-warm-cron.sh                    # same + migrate hint
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER="# alfa-ai inference keep-warm"
LEGACY_MARKER="# alfa-ai inference keep-warm (hub brain)"

remove_local_cron() {
  local had=0
  TMP="$(mktemp)"
  if crontab -l 2>/dev/null | grep -qE 'keep-inference-warm|alfa-ai inference keep-warm'; then
    had=1
  fi
  crontab -l 2>/dev/null | grep -Fv "$MARKER" | grep -Fv "$LEGACY_MARKER" | grep -Fv 'keep-inference-warm.sh' >"$TMP" || true
  crontab "$TMP" 2>/dev/null || true
  rm -f "$TMP"
  if [[ "$had" == "1" ]]; then
    echo "Removed local inference keep-warm crontab entries."
  else
    echo "No local inference keep-warm crontab entries found."
  fi
}

remove_local_cron

echo ""
echo "Keep-warm cron now runs on hub (brain, localhost LiteLLM)."
echo "On hub as operator:"
echo "  bash $REPO_DIR/deploy/cluster-members/hub/install-inference-keep-warm-cron.sh"

if [[ "${1:-}" != "--uninstall-only" ]]; then
  echo ""
  echo "Optional one-shot test on hub:"
  echo "  inference_WARM_LITELLM_BASE=http://127.0.0.1:8413 inference_WARM_CONTRACTS_BOT_URL=http://apps bash scripts/keep-inference-warm.sh"
fi