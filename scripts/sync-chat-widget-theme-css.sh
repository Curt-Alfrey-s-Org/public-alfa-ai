#!/usr/bin/env bash
# Propagate chat panel colors and dock geometry from packages/chat-widget/assets/theme.css into
# the WordPress guest chat plugin :root block.
#
# Hex + geometry SSoT: packages/chat-widget/src/theme.ts
# USPBF static demo: websites/uspbf-static-demo-chat/alfa-demo-chat.css
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
THEME="$ROOT/packages/chat-widget/assets/theme.css"
WP_CSS="$ROOT/websites/alfa-wordpress-plugins/alfa-ai-guest-chat-widget/alfa-ai-chat-widget.css"

if [[ ! -f "$THEME" ]]; then
  echo "ERROR: missing $THEME" >&2
  exit 1
fi
if [[ ! -f "$WP_CSS" ]]; then
  echo "ERROR: missing $WP_CSS" >&2
  exit 1
fi

python3 - "$THEME" "$WP_CSS" << 'PY'
import re
import sys
from pathlib import Path

theme = Path(sys.argv[1]).read_text(encoding="utf-8")
wp = Path(sys.argv[2])
text = wp.read_text(encoding="utf-8")

m = re.search(r":root\s*\{([^}]*)\}", theme, re.S)
if not m:
    raise SystemExit("theme.css missing :root block")

core = m.group(1).strip()
merged = (
    "/* ALFa AI guest chat — colors MUST match packages/chat-widget/src/theme.ts */\n"
    ":root {\n"
    + core
    + "\n"
    "  --alfa-dock-bg: var(--alfa-panel-bg);\n"
    "  --alfa-dock-border: var(--alfa-panel-border);\n"
    "  --alfa-dock-slate-700: var(--alfa-panel-border);\n"
    "  --alfa-dock-slate-600: #1e3a5f;\n"
    "}\n"
)

new_text, n = re.subn(
    r"/\* ALFa AI guest chat.*?\*/\s*:root\s*\{[^}]*\}",
    merged.rstrip(),
    text,
    count=1,
    flags=re.S,
)
if n != 1:
    raise SystemExit(f"Could not patch :root in {wp}")

wp.write_text(new_text, encoding="utf-8")
print(f"[sync-chat-widget-theme-css] OK -> {wp}")
PY

echo "[sync-chat-widget-theme-css] Redeploy WP on apps: sudo bash websites/alfa-wordpress-plugins/install-alfa-ai-guest-chat.sh"
