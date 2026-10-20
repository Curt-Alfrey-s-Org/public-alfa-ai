#!/usr/bin/env bash
# Tier A learning loop on brain (hub): clear wedges, curator, export, feeder probe.
#
# Usage (From hub as operator):
#   cd /mnt/hub/alfa-ai/repo/alfa-ai
#   bash scripts/learning_loop_tier_a.sh
#
# Uses alfa-ai-api container for DB-backed steps (host python lacks psycopg).
# Copies train-export pack to hub-writable agent-audit-logs/train-export on host.
#
# Flags:
#   --skip-clear     Do not clear stuck missions
#   --skip-curator   Skip sleep_curator_nightly.py
#   --skip-export    Skip export_train_pack.py
#   --skip-publish   Skip publish_train_pack_to_hub.sh (after export copy)
#   --skip-feeder    Skip audit_mission_feeder.sh
#   --dry-run-clear  clear_stuck_missions dry_run only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DO_CLEAR=1
DO_CURATOR=1
DO_EXPORT=1
DO_PUBLISH=1
DO_FEEDER=1
CLEAR_DRY=0
EXPORT_HOST="${ALFA_AI_TRAIN_EXPORT_PATH:-/mnt/hub/alfa-ai/agent-audit-logs/train-export}"

for arg in "$@"; do
  case "$arg" in
    --skip-clear) DO_CLEAR=0 ;;
    --skip-curator) DO_CURATOR=0 ;;
    --skip-export) DO_EXPORT=0 ;;
    --skip-publish) DO_PUBLISH=0 ;;
    --skip-feeder) DO_FEEDER=0 ;;
    --dry-run-clear) CLEAR_DRY=1 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

docker_api() {
  if ! sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'alfa-ai-api'; then
    echo "ERROR: alfa-ai-api container not running" >&2
    exit 2
  fi
  sudo docker exec -w /app alfa-ai-api "$@"
}

mkdir -p "${EXPORT_HOST}" 2>/dev/null || {
  EXPORT_HOST="${REPO_ROOT}/.alfa_ai/train-export"
  mkdir -p "${EXPORT_HOST}"
}

echo "== learning_loop_tier_a: start =="
echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "export_host=${EXPORT_HOST}"

if [[ "$DO_CLEAR" -eq 1 ]]; then
  echo "[1/4] clear stuck missions"
  dry_flag="False"
  if [[ "$CLEAR_DRY" -eq 1 ]]; then
    dry_flag="True"
  fi
  docker_api python -c "
from src.ops.mission_wedge import clear_stuck_missions
import json
print(json.dumps(clear_stuck_missions(dry_run=${dry_flag}), indent=2))
"
fi

if [[ "$DO_CURATOR" -eq 1 ]] || [[ "$DO_EXPORT" -eq 1 ]]; then
  if [[ "${ALFA_AI_FLYWHEEL_ENABLED:-0}" == "1" ]]; then
    echo "[2-3/4] data flywheel (MAPE Tier A)"
    fly_args=()
    if [[ "$DO_CURATOR" -eq 0 ]]; then
      fly_args+=(--skip-curator)
    fi
    if [[ "$DO_EXPORT" -eq 0 ]]; then
      fly_args+=(--skip-export)
    fi
    docker_api python scripts/run_data_flywheel.py "${fly_args[@]}"
  else
    if [[ "$DO_CURATOR" -eq 1 ]]; then
      echo "[2/4] sleep curator"
      docker_api python -c "
from src.runtime.sleep_curator import run_sleep_curator
import json
print(json.dumps(run_sleep_curator(), indent=2, default=str))
"
    fi

    if [[ "$DO_EXPORT" -eq 1 ]]; then
      echo "[3/4] export train pack (container -> host)"
      docker_api python -c "
from src.runtime.train_export import export_train_pack
import json
r = export_train_pack()
print(json.dumps(r.to_dict(), indent=2))
"
    fi
  fi
fi

if [[ "$DO_EXPORT" -eq 1 ]]; then
  echo "[3/4] copy train pack to hub export host"
  latest="$(docker_api cat /workspace/.alfa_ai/train-export/LATEST.txt 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -z "${latest}" ]]; then
    echo "WARN: no LATEST.txt in container train-export" >&2
  else
    pack_name="$(basename "${latest}")"
    dest="${EXPORT_HOST}/${pack_name}"
    rm -rf "${dest}"
    mkdir -p "${dest}"
    sudo docker cp "alfa-ai-api:${latest}/." "${dest}/"
    echo "${dest}" > "${EXPORT_HOST}/LATEST.txt"
    echo "copied pack to ${dest}"
    if [[ -f "${dest}/MANIFEST.json" ]]; then
      python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print('counts', m.get('counts'))" "${dest}/MANIFEST.json"
    fi
  fi

  if [[ "$DO_PUBLISH" -eq 1 ]]; then
    echo "[4/5] publish train pack to hub (secret scan + rsync)"
    if [[ -f "${EXPORT_HOST}/LATEST.txt" ]]; then
      pack_path="$(tr -d '\r\n' < "${EXPORT_HOST}/LATEST.txt")"
      bash "${SCRIPT_DIR}/publish_train_pack_to_hub.sh" "${pack_path}"
    else
      bash "${SCRIPT_DIR}/publish_train_pack_to_hub.sh"
    fi
  fi
fi

if [[ "$DO_FEEDER" -eq 1 ]]; then
  echo "[5/5] mission feeder probe"
  if [[ -f "${REPO_ROOT}/deploy/.env" ]]; then
    export ALFA_AI_ENV_FILE="${REPO_ROOT}/deploy/.env"
  fi
  bash "${SCRIPT_DIR}/audit_mission_feeder.sh" || true
fi

echo "== learning_loop_tier_a: done =="
