#!/usr/bin/env bash
# Remove legacy WPBot + chatbot-product-intelligence from alfa WordPress.
# Replaced by alfa-ai-guest-chat-widget → /alfa-ai/api/guest/chat
#
# Usage: sudo bash scripts/remove-legacy-wpbot.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/../alfaqd-website/.env"
MU="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins"

wp() {
  local env_args=()
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    env_args=(
      -e "WORDPRESS_DB_HOST=alfa_db_1"
      -e "WORDPRESS_DB_USER=${MYSQL_USER:-wordpress}"
      -e "WORDPRESS_DB_PASSWORD=${MYSQL_PASSWORD:?set MYSQL_PASSWORD in alfaqd-website/.env}"
      -e "WORDPRESS_DB_NAME=${MYSQL_DATABASE:-wordpress}"
    )
  fi
  docker run --rm --user root --network alfa1_db \
    -v alfa1_wp_data:/var/www/html \
    "${env_args[@]}" \
    wordpress:cli wp "$@" --allow-root
}

echo "=== Remove legacy WPBot from alfa site ==="

if wp plugin is-active chatbot 2>/dev/null; then
  echo "Deactivating WPBot (chatbot)..."
  wp plugin deactivate chatbot
else
  echo "WPBot (chatbot) already inactive."
fi

if [[ -f "$MU/chatbot-product-intelligence.php" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  echo "Archiving mu-plugin chatbot-product-intelligence.php → .bak.${ts}"
  mv "$MU/chatbot-product-intelligence.php" "$MU/chatbot-product-intelligence.php.bak.${ts}"
fi

echo ""
echo "Legacy chatbot removed. Install ALFa AI widget:"
echo "  sudo bash $ROOT/install-alfa-ai-guest-chat.sh"
echo "  cd /home/operator/alfaqd-website && sudo bash bin/wp-cli.sh plugin activate alfa-ai-guest-chat-widget"
