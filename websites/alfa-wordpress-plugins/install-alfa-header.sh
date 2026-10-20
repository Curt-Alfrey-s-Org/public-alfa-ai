#!/usr/bin/env bash
# Install the ALFa header pattern (includes Projects nav link) into the Spectra One theme.
#
# Run on the server where Docker runs (alfa1_wp_data volume).
# Usage: sudo bash install-alfa-header.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADER_SRC="/home/operator/alfa-wordpress-header-pattern.php"
WP_CONTENT="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content"
HEADER_DEST="${WP_CONTENT}/themes/spectra-one/patterns/header.php"

if [ ! -f "${HEADER_SRC}" ]; then
  echo "Error: header pattern not found: ${HEADER_SRC}"
  exit 1
fi

if [ ! -d "${WP_CONTENT}/themes/spectra-one/patterns" ]; then
  echo "Error: Spectra One theme not found at ${WP_CONTENT}/themes/spectra-one"
  exit 1
fi

echo "Installing header pattern with Projects menu link..."
cp "${HEADER_SRC}" "${HEADER_DEST}"
chown www-data:www-data "${HEADER_DEST}" 2>/dev/null || chown 33:33 "${HEADER_DEST}" 2>/dev/null || true
echo "Done. Installed at: ${HEADER_DEST}"
echo "Refresh the site to see Home, About, Projects, Blog, Contact, Rankings in the nav."
