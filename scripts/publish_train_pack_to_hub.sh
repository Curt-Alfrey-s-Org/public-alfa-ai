#!/usr/bin/env bash
# Copy latest train-export pack to hub staging (Tier A -> hub, hub operator).
#
# Usage (From hub as operator):
#   bash scripts/publish_train_pack_to_hub.sh
#   bash scripts/publish_train_pack_to_hub.sh /path/to/export/20260714T120000Z
#
# Env:
#   ALFA_AI_TRAIN_HUB_HINT=/mnt/hub/alfa-ai/training/alfa-train/datasets/from-alfa-ai
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HUB_HINT="${ALFA_AI_TRAIN_HUB_HINT:-/mnt/hub/alfa-ai/training/alfa-train/datasets/from-alfa-ai}"
EXPORT_ROOT="${ALFA_AI_TRAIN_EXPORT_PATH:-/mnt/hub/alfa-ai/agent-audit-logs/train-export}"

if [[ $# -ge 1 ]]; then
  PACK_SRC="$1"
else
  if [[ -f "${EXPORT_ROOT}/LATEST.txt" ]]; then
    PACK_SRC="$(tr -d '\r\n' < "${EXPORT_ROOT}/LATEST.txt")"
  else
    PACK_SRC="$(ls -1dt "${EXPORT_ROOT}"/*/ 2>/dev/null | head -1 || true)"
  fi
fi

if [[ -z "${PACK_SRC}" || ! -d "${PACK_SRC}" ]]; then
  echo "ERROR: no train-export pack found under ${EXPORT_ROOT}" >&2
  echo "Run: python scripts/export_train_pack.py" >&2
  exit 2
fi

PACK_SRC="$(cd "${PACK_SRC}" && pwd)"
PACK_NAME="$(basename "${PACK_SRC}")"
DEST="${HUB_HINT}/${PACK_NAME}"

echo "== publish_train_pack_to_hub =="
echo "src=${PACK_SRC}"
echo "dest=${DEST}"

SCAN_TMP="$(mktemp)"
if ! python3 "${SCRIPT_DIR}/scan_pass_jsonl.py" "${PACK_SRC}" --json > "${SCAN_TMP}"; then
  echo "ERROR: secret scan failed for ${PACK_SRC}" >&2
  cat "${SCAN_TMP}" >&2 || true
  rm -f "${SCAN_TMP}"
  exit 1
fi

if ! mkdir -p "${HUB_HINT}" 2>/dev/null; then
  echo "Creating hub training tree (sudo once on hub)..."
  sudo mkdir -p "${HUB_HINT}"
  sudo chown -R "$(id -un):$(id -gn)" "$(dirname "${HUB_HINT}")" 2>/dev/null || true
fi
mkdir -p "${HUB_HINT}"
rsync -a --delete "${PACK_SRC}/" "${DEST}/"

PYTHONPATH="${REPO_ROOT}" python3 -c "
import json
from pathlib import Path
from src.runtime.train_export import patch_manifest_scan_pass
manifest = Path('${DEST}/MANIFEST.json')
scan = json.load(open('${SCAN_TMP}', encoding='utf-8'))
patch_manifest_scan_pass(manifest, scan)
print('scan_pass ok=', scan.get('ok'), 'hits=', scan.get('hit_count'))
"

rm -f "${SCAN_TMP}"

echo "OK published to ${DEST}"
echo "MANIFEST:"
if [[ -f "${DEST}/MANIFEST.json" ]]; then
  python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print('schema_version=',m.get('schema_version')); print('counts=',m.get('counts')); print('scan_pass=',m.get('scan_pass'))" "${DEST}/MANIFEST.json"
fi
