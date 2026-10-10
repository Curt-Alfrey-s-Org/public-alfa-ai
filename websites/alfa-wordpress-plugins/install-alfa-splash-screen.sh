#!/usr/bin/env bash
# Install ALFa splash screen (rankings-bot SplashLogin parity) into WordPress mu-plugins.
#
# Usage: sudo bash install-alfa-splash-screen.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/alfa-splash-screen"
DEST="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins/alfa-splash-screen"
LOADER="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins/alfa-splash-screen.php"
LOADER_SRC="${SCRIPT_DIR}/alfa-splash-screen-loader.php"
VIDEO_SRC="/home/operator/rankings-bot/frontend/public/assets/video/grok-video-a1fee053-2343-4013-a0de-0445458248cf.mp4"
FLAG_SRC="/home/operator/rankings-bot/frontend/public/flags/us.svg"

if [ ! -d "${SRC}" ]; then
  echo "Error: ${SRC} not found"
  exit 1
fi

if [ ! -f "${VIDEO_SRC}" ]; then
  echo "Error: rankings-bot splash video not found: ${VIDEO_SRC}"
  exit 1
fi

echo "Installing alfa-splash-screen..."
mkdir -p "${DEST}/assets/video" "${DEST}/assets/flags"
cp -v "${LOADER_SRC}" "${LOADER}"
cp -v "${SRC}/alfa-splash-screen.php" "${DEST}/"
cp -v "${SRC}/alfa-splash-screen.css" "${DEST}/"
cp -v "${SRC}/alfa-splash-screen.js" "${DEST}/"
cp -v "${SRC}/splash_config.json" "${DEST}/"
cp -v "${VIDEO_SRC}" "${DEST}/assets/video/"
cp -v "${FLAG_SRC}" "${DEST}/assets/flags/us.svg"
chown -R www-data:www-data "${DEST}" "${LOADER}" 2>/dev/null || chown -R 33:33 "${DEST}" "${LOADER}" 2>/dev/null || true
echo "Done. Open https://www.example.com/ in a new private window to see the splash."
