#!/usr/bin/env bash
# Install canonical ALFa AI guest chat widget into alfa WordPress (alfa1_wp_data).
# Usage: sudo bash install-alfa-ai-guest-chat.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/alfa-ai-guest-chat-widget"
DEST="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/plugins/alfa-ai-guest-chat-widget"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: $SRC not found"
  exit 1
fi

if [[ ! -d "/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/plugins" ]]; then
  echo "ERROR: alfa1_wp_data volume missing. Start alfa WordPress stack first."
  exit 1
fi

echo "Installing alfa-ai-guest-chat-widget..."
mkdir -p "$DEST"
cp -v "$SRC/alfa-ai-guest-chat-widget.php" "$DEST/"
cp -v "$SRC/alfa-ai-chat-widget.js" "$DEST/"
cp -v "$SRC/alfa-ai-chat-widget.css" "$DEST/"
cp -v "$SRC/popup-template.php" "$DEST/"
cp -v "$SRC/faq.md" "$DEST/"
chown -R www-data:www-data "$DEST"

echo "Done. Activate in WP admin or:"
echo "  cd /home/operator/alfaqd-website && sudo bash bin/wp-cli.sh plugin activate alfa-ai-guest-chat-widget"
echo "Also install site chrome (nav + footer): sudo bash ${ROOT}/install-alfa-site-chrome.sh"
