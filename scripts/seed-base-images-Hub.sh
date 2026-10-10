#!/usr/bin/env bash
# Pull Docker Hub / NVIDIA base images once on hub and save gzip tarballs to the hub.
# Builders can `docker load -i …` before offline builds (registry mirror GC fallback).
#
# Run on hub with Docker + pigz:
#   sudo bash scripts/seed-base-images-hub.sh
#
# Output: ${ALFA_HUB}/docker/base-images/<sanitized_ref>.tar.gz
#
# Docs: docs/HUB_ARTIFACTS.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ALFA_HUB:=/mnt/hub/alfa-ai}"
DEST="${ALFA_HUB}/docker/base-images"
mkdir -p "${DEST}"

if ! command -v pigz &>/dev/null; then
  echo "ERROR: pigz not installed (apt install pigz)." >&2
  exit 1
fi

IMAGES=(
  python:3.12-slim
  python:3.12-slim-bookworm
  python:3.11-slim
  python:3.10-slim
  node:20-alpine
  node:20.11.1-alpine
  node:20.19-bookworm-slim
  nginx:alpine
  nginx:1.27-alpine
  nginx:1.29.8-alpine
  nvidia/cuda:12.8.0-runtime-ubuntu22.04
  nvidia/cuda:12.4.1-runtime-ubuntu22.04
)

echo "Saving images -> ${DEST}"

for img in "${IMAGES[@]}"; do
  safe="${img//\//__}"
  safe="${safe//:/_}"
  out="${DEST}/${safe}.tar.gz"
  echo "==> pull + save ${img}"
  docker pull "${img}"
  docker save "${img}" | pigz -9 > "${out}"
  ls -lh "${out}"
done

echo "Done."
