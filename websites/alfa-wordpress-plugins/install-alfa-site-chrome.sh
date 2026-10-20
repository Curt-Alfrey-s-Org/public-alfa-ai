#!/usr/bin/env bash
# Install ALFa Site Chrome (top nav + minimal footer) and remove legacy test-tagline mu-plugin.
#
# Usage: sudo bash install-alfa-site-chrome.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/alfa-site-chrome"
MU_PLUGINS="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins"
DEST="${MU_PLUGINS}"
LEGACY_TAGLINE="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins/test-tagline.php"
WP_CLI="/home/operator/alfaqd-website/bin/wp-cli.sh"

if [ ! -d "${SRC}" ]; then
  echo "Error: source not found: ${SRC}"
  exit 1
fi

echo "Installing alfa-site-chrome mu-plugin (must be top-level .php in mu-plugins)..."
cp -v "${SRC}/alfa-site-chrome.php" "${DEST}/alfa-site-chrome.php"
cp -v "${SRC}/alfa-site-chrome.css" "${DEST}/alfa-site-chrome.css"
chown www-data:www-data "${DEST}/alfa-site-chrome.php" "${DEST}/alfa-site-chrome.css" 2>/dev/null || \
  chown 33:33 "${DEST}/alfa-site-chrome.php" "${DEST}/alfa-site-chrome.css" 2>/dev/null || true
rm -rf "${MU_PLUGINS}/alfa-site-chrome" 2>/dev/null || true

if [ -f "${LEGACY_TAGLINE}" ]; then
  echo "Removing legacy test-tagline footer injection..."
  rm -f "${LEGACY_TAGLINE}"
fi

if [ -f "${WP_CLI}" ]; then
  echo "Syncing footer template part to single credit line..."
  FOOTER_TMP="$(mktemp)"
  cat > "${FOOTER_TMP}" <<'EOF'
<!-- wp:paragraph -->
<p class="alfa-site-chrome-footer__credit">Website created and self hosted by example N Alfrey Jr.</p>
<!-- /wp:paragraph -->
EOF
  sudo bash "${WP_CLI}" post update 58 --post_content="$(cat "${FOOTER_TMP}")" 2>/dev/null || \
    echo "Warning: could not update footer template part via wp-cli."
  rm -f "${FOOTER_TMP}"
fi

echo "Done. Refresh https://www.example.com/ to verify nav, chat FAB, and footer."
