#!/usr/bin/env bash
# Install the Market Bot Responsive Grid (includes Credit Check Bot button) as a
# Must-Use Plugin so it runs automatically—no WordPress admin visit or activation.
# Homepage at www.example.com will show the grid at the bottom.
#
# Run on the server where Docker runs (alfa1_wp_data volume).
# Usage: sudo bash install-credit-check-bot-button.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_FILE="market-bot-responsive-grid.php"
WP_CONTENT="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content"
MU_PLUGINS_DIR="${WP_CONTENT}/mu-plugins"

if [ ! -f "${SCRIPT_DIR}/${PLUGIN_FILE}" ]; then
  echo "Error: ${PLUGIN_FILE} not found in ${SCRIPT_DIR}"
  exit 1
fi

if [ ! -d "${WP_CONTENT}" ]; then
  echo "Error: ALFa WordPress wp-content path not found: ${WP_CONTENT}"
  echo "Ensure Docker volume alfa1_wp_data exists and this script is run on the correct server."
  exit 1
fi

echo "Installing Market Bot Responsive Grid (with Credit Check Bot) as Must-Use Plugin..."
# Remove from regular plugins so only mu-plugin runs (avoids duplicate grid)
PLUGINS_GRID_FILE="${WP_CONTENT}/plugins/market-bot-responsive-grid.php"
PLUGINS_GRID_DIR="${WP_CONTENT}/plugins/market-bot-responsive-grid"
if [ -f "${PLUGINS_GRID_FILE}" ]; then
  rm -f "${PLUGINS_GRID_FILE}"
  echo "Removed duplicate flat file from plugins/."
fi
if [ -d "${PLUGINS_GRID_DIR}" ]; then
  rm -rf "${PLUGINS_GRID_DIR}"
  echo "Removed duplicate from plugins/ so only mu-plugin runs."
fi
mkdir -p "${MU_PLUGINS_DIR}"
cp "${SCRIPT_DIR}/${PLUGIN_FILE}" "${MU_PLUGINS_DIR}/"
chown www-data:www-data "${MU_PLUGINS_DIR}/${PLUGIN_FILE}" 2>/dev/null || chown 33:33 "${MU_PLUGINS_DIR}/${PLUGIN_FILE}" 2>/dev/null || true
echo "Done. Installed at: ${MU_PLUGINS_DIR}/${PLUGIN_FILE}"
echo ""
echo "No WordPress admin visit needed—mu-plugins load automatically. Refresh the homepage to see the grid."
