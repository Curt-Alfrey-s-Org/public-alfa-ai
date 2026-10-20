#!/usr/bin/env bash
# Remove ALFa splash screen mu-plugin (restores normal homepage).
# Usage: sudo bash uninstall-alfa-splash-screen.sh

set -euo pipefail

LOADER="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins/alfa-splash-screen.php"
DEST="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins/alfa-splash-screen"

rm -f "${LOADER}"
rm -rf "${DEST}"
echo "Removed splash screen plugin. Homepage should load normally again."
