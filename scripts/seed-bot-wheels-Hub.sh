#!/usr/bin/env bash
# Populate hub hub PyPI wheels for workspace bots/apps (Pattern A repos).
#
# Run on hub (hub) as root after placing sibling repos next to alfa-ai under
# WORKSPACE_ROOT (default: parent of this repo).
#
#   sudo bash scripts/seed-bot-wheels-hub.sh
#
# Writes: ${HUB_ROOT}/bots/*.whl (cp310 + cp311 + cp312 manylinux wheels).
# Hub root defaults to /mnt/hub/alfa-ai/wheels (same dataset as ml-base wheels).
#
# After seeding: bash scripts/sync-bot-wheels-from-hub.sh (on builders).
#
# Docs: docs/HUB_ARTIFACTS.md, docs/CLUSTER_SHARED_STORAGE.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALFA_AI_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
: "${WORKSPACE_ROOT:=$(cd "${ALFA_AI_ROOT}/.." && pwd)}"
: "${HUB_ROOT:=/mnt/hub/alfa-ai/wheels}"
: "${BOTS_DEST:=${HUB_ROOT}/bots}"

mkdir -p "${BOTS_DEST}"

echo "Hub wheels dir: ${BOTS_DEST}"
echo "Workspace root: ${WORKSPACE_ROOT} (expects rankings-bot, contracts-bot, … next to alfa-ai)"

require_req() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing requirements file: $f" >&2
    exit 1
  fi
}

require_req "${WORKSPACE_ROOT}/rankings-bot/requirements-api.txt"
require_req "${WORKSPACE_ROOT}/rankings-bot/requirements-deps.txt"
require_req "${WORKSPACE_ROOT}/credit-check-bot/requirements.txt"
require_req "${WORKSPACE_ROOT}/rv-auto-finder/requirements-api.txt"
require_req "${WORKSPACE_ROOT}/rv-auto-finder/requirements-deps.txt"
require_req "${WORKSPACE_ROOT}/atems/requirements.txt"
require_req "${WORKSPACE_ROOT}/auth-service/requirements.txt"
require_req "${WORKSPACE_ROOT}/market-pie5-bot/requirements.txt"
require_req "${WORKSPACE_ROOT}/contracts-bot/requirements.txt"

run_download_pass() {
  local py_tag="$1"
  local img="$2"
  shift 2
  # One requirements file per pip resolve — repos pin bcrypt differently
  # (rankings <4.1.0 vs bots ==4.1.3); merging -r files causes ResolutionImpossible.
  local -a req_files=("$@")

  echo ""
  echo "==> pip download (Python ${py_tag}) into ${BOTS_DEST} (${#req_files[@]} requirements files)"

  local req_list=""
  for f in "${req_files[@]}"; do
    req_list+="${req_list:+ }$(printf '%q' "$f")"
  done

  # shellcheck disable=SC2086
  docker run --rm -i \
    -v "${BOTS_DEST}:/wheels" \
    -v "${WORKSPACE_ROOT}:/workspace:ro" \
    "${img}" \
    bash -s -- "${py_tag}" ${req_list} <<'EOS'
set -euo pipefail
py_tag="$1"
shift

mkdir -p /wheels/.pip-cache /wheels/.tmp
chmod 1777 /wheels/.tmp 2>/dev/null || true
export PIP_CACHE_DIR=/wheels/.pip-cache TMPDIR=/wheels/.tmp

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates
python -m pip install -q "pip>=24" setuptools wheel

download_one() {
  local req="$1"
  echo ""
  echo "---- ${req} (py ${py_tag}) ----"
  set +e
  python -m pip download --dest /wheels \
    --python-version "${py_tag}" \
    --platform manylinux_2_28_x86_64 \
    --platform manylinux2014_x86_64 \
    --only-binary=:all: \
    --extra-index-url https://pypi.org/simple \
    -r "${req}"
  local st=$?
  set -e
  if [[ ${st} -ne 0 ]]; then
    echo "WARN: --only-binary failed for ${req}; retry without platform pins (sdists)..." >&2
    python -m pip download --dest /wheels \
      --extra-index-url https://pypi.org/simple \
      -r "${req}"
  fi
}

for req in "$@"; do
  download_one "${req}"
done

echo "==> audit: wheels >= 100 MiB (py ${py_tag} pass)"
find /wheels -maxdepth 1 -type f -name '*.whl' -size +100M -exec ls -lh {} + 2>/dev/null | head -20 || true
EOS
}

run_download_pass 312 python:3.12-slim-bookworm \
  /workspace/rankings-bot/requirements-api.txt \
  /workspace/rankings-bot/requirements-deps.txt \
  /workspace/credit-check-bot/requirements.txt \
  /workspace/rv-auto-finder/requirements-api.txt \
  /workspace/rv-auto-finder/requirements-deps.txt

run_download_pass 311 python:3.11-slim-bookworm \
  /workspace/atems/requirements.txt \
  /workspace/auth-service/requirements.txt

run_download_pass 310 python:3.10-slim-bookworm \
  /workspace/market-pie5-bot/requirements.txt \
  /workspace/contracts-bot/requirements.txt

echo ""
echo "Done. Wheel count (approx): $(find "${BOTS_DEST}" -maxdepth 1 -name '*.whl' | wc -l)"
echo "Next on builders: bash scripts/sync-bot-wheels-from-hub.sh"
