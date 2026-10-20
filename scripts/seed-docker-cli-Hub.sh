#!/usr/bin/env bash
# Download Docker static CLI tarball for rankings-bot Dockerfile.base (hub-first).
#
# Run on hub (hub):
#   sudo bash scripts/seed-docker-cli-hub.sh
#
# Writes: ${ALFA_HUB}/installers/docker-cli/docker-${DOCKER_CLI_VERSION}.tgz
set -euo pipefail

: "${ALFA_HUB:=/mnt/hub/alfa-ai}"
: "${DOCKER_CLI_VERSION:=27.4.1}"

DEST="${ALFA_HUB}/installers/docker-cli"
mkdir -p "${DEST}"
TGZ="${DEST}/docker-${DOCKER_CLI_VERSION}.tgz"
URL="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz"

if [[ -s "${TGZ}" ]]; then
  echo "Already present: ${TGZ}"
  exit 0
fi

echo "Downloading ${URL} -> ${TGZ}"
curl -fsSL -o "${TGZ}.partial" "${URL}"
mv "${TGZ}.partial" "${TGZ}"
ls -lh "${TGZ}"
