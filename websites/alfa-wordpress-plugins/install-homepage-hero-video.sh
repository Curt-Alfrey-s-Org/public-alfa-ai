#!/usr/bin/env bash
# Swap homepage hero background (Blog Home template) from wolf GIF to rankings-bot MP4.
# Does not add a splash overlay — only updates the existing UAG container block.
#
# Usage: sudo bash install-homepage-hero-video.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIDEO_SRC="/home/operator/rankings-bot/frontend/public/assets/video/grok-video-a1fee053-2343-4013-a0de-0445458248cf.mp4"

if [ ! -f "${VIDEO_SRC}" ]; then
  echo "Error: video not found: ${VIDEO_SRC}"
  exit 1
fi

python3 "${SCRIPT_DIR}/scripts/swap-homepage-hero-video.py"
echo "Done. Hard-refresh https://www.example.com/ to see the new background video."
