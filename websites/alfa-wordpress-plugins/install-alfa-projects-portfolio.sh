#!/usr/bin/env bash
# Install ALFa Projects Portfolio as a Must-Use Plugin and create /projects/ page.
#
# Run on the server where Docker runs (alfa1_wp_data volume).
# Usage: sudo bash install-alfa-projects-portfolio.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_FILE="alfa-projects-portfolio.php"
WP_CONTENT="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content"
MU_PLUGINS_DIR="${WP_CONTENT}/mu-plugins"
ALFAQD_WEBSITE="/home/operator/alfaqd-website"

if [ ! -f "${SCRIPT_DIR}/${PLUGIN_FILE}" ]; then
  echo "Error: ${PLUGIN_FILE} not found in ${SCRIPT_DIR}"
  exit 1
fi

if [ ! -d "${WP_CONTENT}" ]; then
  echo "Error: ALFa WordPress wp-content path not found: ${WP_CONTENT}"
  echo "Ensure Docker volume alfa1_wp_data exists and this script is run on the correct server."
  exit 1
fi

echo "Installing ALFa Projects Portfolio as Must-Use Plugin..."
mkdir -p "${MU_PLUGINS_DIR}"
cp "${SCRIPT_DIR}/${PLUGIN_FILE}" "${MU_PLUGINS_DIR}/"
chown www-data:www-data "${MU_PLUGINS_DIR}/${PLUGIN_FILE}" 2>/dev/null || chown 33:33 "${MU_PLUGINS_DIR}/${PLUGIN_FILE}" 2>/dev/null || true
echo "Done. Installed at: ${MU_PLUGINS_DIR}/${PLUGIN_FILE}"

if [ -x "${ALFAQD_WEBSITE}/bin/wp-cli.sh" ]; then
  echo ""
  echo "Ensuring /projects/ page exists with [alfa_projects] shortcode..."
  PAGE_ID="$(cd "${ALFAQD_WEBSITE}" && sudo bash bin/wp-cli.sh post list --post_type=page --name=projects --field=ID --format=ids 2>/dev/null || true)"
  if [ -n "${PAGE_ID}" ]; then
    cd "${ALFAQD_WEBSITE}" && sudo bash bin/wp-cli.sh post update "${PAGE_ID}" --post_content='[alfa_projects]' --post_status=publish
    echo "Updated existing Projects page (ID ${PAGE_ID})."
  else
    cd "${ALFAQD_WEBSITE}" && sudo bash bin/wp-cli.sh post create --post_type=page --post_title='Projects' --post_name='projects' --post_content='[alfa_projects]' --post_status=publish
    echo "Created new Projects page."
  fi
  echo "Projects page: https://www.example.com/projects/"
else
  echo "Note: wp-cli not found at ${ALFAQD_WEBSITE}/bin/wp-cli.sh — create a page manually with shortcode [alfa_projects]."
fi

echo ""
echo "Refresh https://www.example.com/projects/ to see the portfolio."
