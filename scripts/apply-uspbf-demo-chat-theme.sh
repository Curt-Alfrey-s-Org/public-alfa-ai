#!/usr/bin/env bash
# Apply canonical ALFa demo dock to USPBF static site AND maintenance page on probilliards.
# Public uspbf.com defaults to maintenance mode — both trees must stay in sync.
# Colors SSoT: packages/chat-widget/src/theme.ts
#
# Run on canonical host (probilliards):
#   bash /home/operator/alfa-ai/scripts/apply-uspbf-demo-chat-theme.sh /home/operator/USPBF
set -euo pipefail

USPBF_ROOT="${1:-/home/operator/USPBF}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALFA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REF="$ALFA_ROOT/websites/uspbf-static-demo-chat"
SITE="$USPBF_ROOT/nginx-config/site"
MAINT="$USPBF_ROOT/nginx-config/maintenance"
NGINX_MAINT="$USPBF_ROOT/nginx-config/uspbf-nginx-maintenance.conf"
JS="$SITE/js/alfa-demo-chat.js"
CSS="$SITE/css/style.css"
AVATAR_SRC="${2:-}"

if [[ ! -f "$JS" ]] || [[ ! -f "$CSS" ]]; then
  echo "ERROR: USPBF site tree not found under $USPBF_ROOT" >&2
  exit 1
fi

mkdir -p "$SITE/branding" "$MAINT/branding" "$MAINT/js" "$MAINT/css"

if [[ -z "$AVATAR_SRC" ]]; then
  for candidate in \
    "$ALFA_ROOT/frontend/public/branding/alfa-ai-avatar.png" \
    "/home/operator/rankings-bot/frontend/public/branding/alfa-ai-avatar.png" \
    "/home/operator/rankings-bot/frontend/dist/branding/alfa-ai-avatar.png"; do
    if [[ -f "$candidate" ]]; then
      AVATAR_SRC="$candidate"
      break
    fi
  done
fi

if [[ -z "$AVATAR_SRC" ]] || [[ ! -f "$AVATAR_SRC" ]]; then
  echo "ERROR: canonical alfa-ai-avatar.png not found; pass path as arg 2" >&2
  exit 1
fi

cp "$AVATAR_SRC" "$SITE/branding/alfa-ai-avatar.png"
cp "$AVATAR_SRC" "$MAINT/branding/alfa-ai-avatar.png"
size="$(wc -c < "$SITE/branding/alfa-ai-avatar.png" | tr -d ' ')"
echo "[apply-uspbf-demo] avatar ${size} bytes -> site + maintenance"

python3 - "$JS" "$CSS" "$REF/alfa-demo-chat.css" << 'PY'
import re
import sys
from pathlib import Path

js = Path(sys.argv[1])
css = Path(sys.argv[2])
canonical_css = Path(sys.argv[3]).read_text(encoding="utf-8")

old_avatar = '<div class="alfa-demo__avatar" aria-hidden="true">A</div>'
new_avatar = (
    '<img class="alfa-demo__avatar" src="/branding/alfa-ai-avatar.png" '
    'alt="" width="28" height="28" />'
)
text = js.read_text(encoding="utf-8")
if old_avatar in text:
    js.write_text(text.replace(old_avatar, new_avatar), encoding="utf-8")
    print("[apply-uspbf-demo] JS avatar -> PNG")
elif "alfa-ai-avatar.png" in text:
    print("[apply-uspbf-demo] JS already uses PNG avatar")
else:
    raise SystemExit("Could not find avatar marker in alfa-demo-chat.js")

css_text = css.read_text(encoding="utf-8")
marker = "/* --- example Alfrey"
if marker in css_text:
    before, after = css_text.split(marker, 1)
    before = re.sub(
        r"/\* ALFa USPBF.*?\*/\s*\.alfa-demo \{.*?(?=/\* --- example Alfrey)",
        "",
        before,
        count=1,
        flags=re.DOTALL,
    )
    if ".alfa-demo {" not in before:
        css_text = before.rstrip() + "\n\n" + canonical_css + "\n\n" + marker + after
    else:
        css_text = re.sub(
            r"\.alfa-demo \{.*?(?=/\* --- example Alfrey)",
            canonical_css.strip() + "\n\n",
            before,
            count=1,
            flags=re.DOTALL,
        ) + marker + after
else:
    if ".alfa-demo {" in css_text:
        css_text = re.sub(
            r"\.alfa-demo \{.*",
            canonical_css.strip(),
            css_text,
            count=1,
            flags=re.DOTALL,
        )
    else:
        css_text = css_text.rstrip() + "\n\n" + canonical_css + "\n"

css.write_text(css_text, encoding="utf-8")
print("[apply-uspbf-demo] site CSS replaced with canonical dock styles")
PY

cp "$REF/alfa-demo-chat.css" "$MAINT/css/alfa-demo-chat.css"
cp "$SITE/js/api.js" "$MAINT/js/api.js"
cp "$JS" "$MAINT/js/alfa-demo-chat.js"
cp "$REF/maintenance/index.html" "$MAINT/index.html"
echo "[apply-uspbf-demo] maintenance bundle synced (index + js + css + branding)"

if [[ -f "$NGINX_MAINT" ]]; then
  bash "$SCRIPT_DIR/patch-uspbf-maintenance-api-proxy.sh" "$NGINX_MAINT"
fi

for html in "$SITE"/*.html; do
  [[ -f "$html" ]] || continue
  if grep -q 'style.css?v=' "$html"; then
    ver="$(grep -o 'style.css?v=[0-9]*' "$html" | head -1 | cut -d= -f2)"
    if [[ -n "$ver" ]]; then
      next=$((ver + 1))
      sed -i "s/style.css?v=${ver}/style.css?v=${next}/" "$html"
    fi
  fi
done

echo "[apply-uspbf-demo] Done. Rebuild:"
echo "  cd $USPBF_ROOT && docker compose build uspbf-nginx && docker compose up -d --force-recreate uspbf-nginx"
