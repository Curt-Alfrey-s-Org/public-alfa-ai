#!/usr/bin/env bash
# Seed PyPI wheels for victron-ble2mqtt-integration onto the hub hub.
#
# Run on hub (hub) once per requirements.lock bump — downloads wheels for
# linux/arm64 (Pi) and linux/amd64 into:
#   ${HUB_ROOT}/wheels/victron/*.whl
#
# Uses the host's native python image (amd64 on typical hub) and pip's
# --platform flags so we never exec ARM binaries on x86 (avoids "exec format error").
# Policy: docs/HUB_ARTIFACTS.md, .cursor/rules/hub-hub-first.mdc
#
# --- hub: if path .../repo/alfa-ai does not exist yet ---
# Shell note: default hub login shell may be tcsh — run each command as its own line;
# do not paste ".../" or bash-style comments on the same line as cd.
#
# Option A — clone once under the hub dataset (recommended):
#   mkdir -p /mnt/hub/alfa-ai/repo
#   cd /mnt/hub/alfa-ai/repo
#   git clone https://github.com/example/alfa-ai.git
#   git clone https://github.com/example/victron-ble2mqtt-integration.git
#   sudo bash /mnt/hub/alfa-ai/repo/alfa-ai/scripts/seed-victron-wheels-hub.sh
#
# Option B — no git clone; fetch script + lock then seed (GitHub download runs only on hub):
#   curl -fsSL -o /tmp/requirements.victron.lock \
#     https://raw.githubusercontent.com/example/victron-ble2mqtt-integration/main/requirements.lock
#   curl -fsSL -o /tmp/seed-victron-wheels-hub.sh \
#     https://raw.githubusercontent.com/example/alfa-ai/main/scripts/seed-victron-wheels-hub.sh
#   sudo REQUIREMENTS_FILE=/tmp/requirements.victron.lock bash /tmp/seed-victron-wheels-hub.sh
#
# Usage (when alfa-ai repo already exists on hub):
#   sudo bash scripts/seed-victron-wheels-hub.sh
#   REQUIREMENTS_FILE=/path/to/victron-ble2mqtt-integration/requirements.lock sudo -E bash scripts/seed-victron-wheels-hub.sh
#
set -euo pipefail

HUB_ROOT="${HUB_ROOT:-/mnt/hub/alfa-ai}"
WHEEL_DIR="${VICTRON_WHEEL_DIR:-${HUB_ROOT}/wheels/victron}"
IMAGE="${PYTHON_IMAGE:-python:3.11-bookworm}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

default_req="$REPO_ROOT/../victron-ble2mqtt-integration/requirements.lock"
if [[ -f "/mnt/hub/alfa-ai/repo/victron-ble2mqtt-integration/requirements.lock" ]]; then
  default_req="/mnt/hub/alfa-ai/repo/victron-ble2mqtt-integration/requirements.lock"
fi
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-$default_req}"

if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
  echo "ERROR: requirements.lock not found: $REQUIREMENTS_FILE" >&2
  echo "Set REQUIREMENTS_FILE= to victron-ble2mqtt-integration/requirements.lock" >&2
  exit 2
fi

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "ERROR: run as root on hub (needs docker + hub paths)." >&2
  exit 2
fi

mkdir -p "$WHEEL_DIR"
chmod 755 "$WHEEL_DIR"

tmp_req="$(mktemp)"
cleanup() { rm -f "$tmp_req"; }
trap cleanup EXIT
cp -a "$REQUIREMENTS_FILE" "$tmp_req"

echo "==> Seeding victron wheels -> $WHEEL_DIR"
echo "    requirements: $REQUIREMENTS_FILE"
echo "    image: $IMAGE (native arch); pip --platform manylinux aarch64 + x86_64"

# Separate downloads per architecture: pip with multiple --platform flags
# picks ONE wheel per package (the first match). Compiled packages like
# psutil publish different wheels per arch, so a single pass can grab
# x86_64 psutil and skip the aarch64 one the Pi needs.
download_arch() {
  local label="$1"; shift
  echo "    pip download ($label) ..."
  docker run --rm \
    --platform linux/amd64 \
    -v "${WHEEL_DIR}:/out" \
    -v "${tmp_req}:/req.txt:ro" \
    "$IMAGE" \
    bash -lc "
set -euo pipefail
pip install -q pip setuptools wheel
pip download --no-cache-dir --only-binary=:all: -r /req.txt -d /out \
  --python-version 3.11 $*
"
}

download_arch "aarch64" \
  --platform manylinux2014_aarch64 \
  --platform manylinux_2_17_aarch64 \
  --platform manylinux_2_28_aarch64 \
  --platform linux_aarch64 \
  --platform any

download_arch "x86_64" \
  --platform manylinux2014_x86_64 \
  --platform manylinux_2_17_x86_64 \
  --platform manylinux_2_28_x86_64 \
  --platform linux_x86_64 \
  --platform any

cnt="$(find "$WHEEL_DIR" -maxdepth 1 -type f -name '*.whl' | wc -l)"
echo "==> Done. Wheel files in $WHEEL_DIR: $cnt"
echo "    NFS clients: /mnt/cluster/wheels/victron/"
echo "    SMB: \\\\hub\\petals-wheels\\victron\\"

# --- Docker image tarballs (one-time pulls on hub, then LAN-only) ---
IMAGES_DIR="${HUB_ROOT}/docker-images"
mkdir -p "$IMAGES_DIR"

seed_image_tarball() {
  local image="$1" tarball="$2" label="$3"
  if [[ -f "${IMAGES_DIR}/${tarball}" ]]; then
    echo "==> ${label} tarball already exists: ${IMAGES_DIR}/${tarball} — skipping."
    return 0
  fi
  echo "==> Pulling ${label} image (one-time on hub): ${image} ..."
  docker pull "$image"
  echo "==> Saving -> ${IMAGES_DIR}/${tarball} ..."
  docker save "$image" | gzip > "${IMAGES_DIR}/${tarball}.tmp"
  mv "${IMAGES_DIR}/${tarball}.tmp" "${IMAGES_DIR}/${tarball}"
  echo "==> ${label} tarball saved ($(du -h "${IMAGES_DIR}/${tarball}" | cut -f1))."
}

seed_image_tarball "ghcr.io/home-assistant/home-assistant:stable" \
  "home-assistant-stable.tar.gz" "Home Assistant"

seed_image_tarball "louislam/dockge:1" \
  "dockge-1.tar.gz" "Dockge"

seed_image_tarball "containrrr/watchtower:1.7.1" \
  "watchtower-1.7.1.tar.gz" "Watchtower"
