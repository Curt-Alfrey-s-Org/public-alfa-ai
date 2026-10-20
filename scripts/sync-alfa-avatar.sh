#!/usr/bin/env bash
# Copy the canonical ALFa avatar from the brain SPA public tree into the
# @alfa-ai/chat-widget package assets. Run after replacing the master PNG.
#
# Master:  frontend/public/branding/alfa-ai-avatar.png
# Package: packages/chat-widget/assets/alfa-ai-avatar.png
#
# Full rollout: docs/ALFA_AI_CHAT_WIDGETS.md (Avatar-only rollout)
#               .cursor/plans/UNIFIED_CHAT_WIDGET.md (Section 8)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MASTER="$ROOT/frontend/public/branding/alfa-ai-avatar.png"
PKG="$ROOT/packages/chat-widget/assets/alfa-ai-avatar.png"

if [[ ! -f "$MASTER" ]]; then
  echo "ERROR: missing master avatar: $MASTER" >&2
  exit 1
fi

mkdir -p "$(dirname "$PKG")"
cp "$MASTER" "$PKG"

size="$(wc -c < "$MASTER" | tr -d ' ')"
echo "[sync-alfa-avatar] OK ${size} bytes -> $PKG"
