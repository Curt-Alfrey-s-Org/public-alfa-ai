#!/usr/bin/env bash
# Install ALFa example Alfrey meme (rankings-bot ExampleAlfreyMeme parity) into WordPress mu-plugins.
# Homepage easter egg: Iron Man "box of scraps" clip with three captions.
#
# Usage: sudo bash install-alfa-example-meme.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/alfa-example-meme"
DEST="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins/alfa-example-meme"
LOADER="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins/alfa-example-meme.php"
LOADER_SRC="${SCRIPT_DIR}/alfa-example-meme-loader.php"
VIDEO_SRC="${SRC}/assets/memes/example-alfrey-cave-scraps.mp4"

if [ ! -d "${SRC}" ]; then
  echo "Error: ${SRC} not found"
  exit 1
fi

if [ ! -f "${VIDEO_SRC}" ]; then
  echo "Error: meme video not found in plugin source: ${VIDEO_SRC}"
  exit 1
fi

echo "Installing alfa-example-meme..."
mkdir -p "${DEST}/assets/memes"
cp -v "${LOADER_SRC}" "${LOADER}"
cp -v "${SRC}/alfa-example-meme.php" "${DEST}/"
cp -v "${SRC}/alfa-example-meme.css" "${DEST}/"
cp -v "${SRC}/alfa-example-meme.js" "${DEST}/"
cp -v "${VIDEO_SRC}" "${DEST}/assets/memes/"
chown -R www-data:www-data "${DEST}" "${LOADER}" 2>/dev/null || chown -R 33:33 "${DEST}" "${LOADER}" 2>/dev/null || true
echo "Done. Hard-refresh https://www.example.com/ to see the meme (bottom-left)."
