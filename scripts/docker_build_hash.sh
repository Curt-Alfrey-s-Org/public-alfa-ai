#!/usr/bin/env bash
# Content hash for Docker image inputs (rankings-bot scripts/docker_build_hash.sh pattern, ALFa AI paths).
# Usage: export BUILD_HASH=$(./scripts/docker_build_hash.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_ROOT"

if command -v sha256sum &>/dev/null; then
  out_hash() { sha256sum | awk '{print $1}'; }
elif command -v shasum &>/dev/null; then
  out_hash() { shasum -a 256 | awk '{print $1}'; }
else
  echo "unknown"
  exit 0
fi

# Stream archive of inputs (avoids ARG_MAX from xargs cat on large trees).
if command -v tar &>/dev/null; then
  tar -cf - \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='node_modules' \
    --exclude='frontend/dist' \
    --exclude='.git' \
    src frontend \
    deploy/Dockerfile.api deploy/docker-compose.yml \
    requirements.txt pyproject.toml 2>/dev/null | out_hash
else
  echo "unknown"
fi
