#!/usr/bin/env bash
# Remove legacy Market Bot Test mu-plugin that injected Custom Software Designer footer text.
# Usage: sudo bash scripts/remove-test-tagline.sh

set -euo pipefail

LEGACY="/var/lib/docker/volumes/alfa1_wp_data/_data/wp-content/mu-plugins/test-tagline.php"

if [ -f "${LEGACY}" ]; then
  rm -f "${LEGACY}"
  echo "Removed ${LEGACY}"
else
  echo "Already removed: ${LEGACY}"
fi
