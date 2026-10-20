#!/usr/bin/env bash
# Register alfa Docker cleanup as a hub Cron Job (System Settings -> Advanced -> Cron Jobs).
# Official API: https://api.hub.com/v25.10/api_methods_cronjob.create.html
#
# Usage (on hub as operator):
#   bash deploy/cluster-members/hub/install-docker-cleanup-cron.sh
#   bash deploy/cluster-members/hub/install-docker-cleanup-cron.sh --uninstall
#
# Schedule: Sunday 03:00 (staggered fleet; see docs/operations/DOCKER_HOST_CLEANUP.md)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
REPO_CLEANUP="$REPO_DIR/deploy/cluster-members/_common/docker-host-cleanup.sh"
PERSIST_DIR="/mnt/hub/alfa-ai/scripts"
PERSIST_CLEANUP="$PERSIST_DIR/docker-host-cleanup.sh"
DESC="alfa docker host cleanup"
# hub cron schedule: Sunday 03:00
MINUTE="0"
HOUR="3"
DOW="0"

if [[ -f "$REPO_CLEANUP" ]]; then
  SOURCE_CLEANUP="$REPO_CLEANUP"
elif [[ -f "$SCRIPT_DIR/../_common/docker-host-cleanup.sh" ]]; then
  SOURCE_CLEANUP="$SCRIPT_DIR/../_common/docker-host-cleanup.sh"
else
  echo "ERROR: missing docker-host-cleanup.sh" >&2
  exit 1
fi

sudo mkdir -p "$PERSIST_DIR"
sudo install -m 0755 "$SOURCE_CLEANUP" "$PERSIST_CLEANUP"
# Hub mode + scheduled; log under pool so it survives.
RUN_CMD="ALFA_DOCKER_CLEANUP_MODE=scheduled ALFA_HUB_ROOT=/mnt/hub/alfa-ai bash $PERSIST_CLEANUP >> /mnt/hub/alfa-ai/logs/alfa-docker-cleanup.log 2>&1"
sudo mkdir -p /mnt/hub/alfa-ai/logs

if [[ "${1:-}" == "--uninstall" ]]; then
  if ! command -v midclt >/dev/null 2>&1; then
    echo "ERROR: midclt not found; remove Cron Job manually in hub UI" >&2
    exit 1
  fi
  mapfile -t IDS < <(midclt call cronjob.query 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
needle = "alfa docker host cleanup"
for row in data:
    blob = ((row.get("description") or "") + " " + (row.get("command") or "")).lower()
    if needle in blob:
        print(row.get("id", ""))
' || true)
  if [[ ${#IDS[@]} -eq 0 ]]; then
    echo "No cronjob matched description; nothing to remove."
    exit 0
  fi
  for id in "${IDS[@]}"; do
    [[ -n "$id" ]] || continue
    midclt call cronjob.delete "$id"
    echo "Removed cronjob id=$id"
  done
  exit 0
fi

echo "== hub Cron Job: $DESC (Sun ${HOUR}:${MINUTE}) =="

if ! command -v midclt >/dev/null 2>&1; then
  echo "midclt not available; add manually in hub UI:"
  echo "  System Settings -> Advanced -> Cron Jobs"
  echo "  description=$DESC"
  echo "  user=root"
  echo "  schedule: minute=$MINUTE hour=$HOUR dow=$DOW (Sunday)"
  echo "  command=$RUN_CMD"
  exit 1
fi

EXISTING="$(midclt call cronjob.query 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
needle = "alfa docker host cleanup"
for row in data:
    blob = ((row.get("description") or "") + " " + (row.get("command") or "")).lower()
    if needle in blob:
        print(row.get("id", ""))
        break
' || true)"

PAYLOAD="$(
  ALFA_CRON_CMD="$RUN_CMD" ALFA_CRON_DESC="$DESC" \
  ALFA_CRON_MINUTE="$MINUTE" ALFA_CRON_HOUR="$HOUR" ALFA_CRON_DOW="$DOW" \
  python3 - <<'PY'
import json, os
print(json.dumps({
    "command": os.environ["ALFA_CRON_CMD"],
    "user": "root",
    "enabled": True,
    "description": os.environ["ALFA_CRON_DESC"],
    "stdout": True,
    "stderr": False,
    "schedule": {
        "minute": os.environ["ALFA_CRON_MINUTE"],
        "hour": os.environ["ALFA_CRON_HOUR"],
        "dom": "*",
        "month": "*",
        "dow": os.environ["ALFA_CRON_DOW"],
    },
}))
PY
)"

if [[ -n "$EXISTING" ]]; then
  # cronjob.update takes id and data as separate args (hub API).
  midclt call cronjob.update "$EXISTING" "$PAYLOAD"
  echo "Updated cronjob id=$EXISTING via midclt."
else
  midclt call cronjob.create "$PAYLOAD"
  echo "Created cronjob via midclt."
fi

echo "UI: System Settings -> Advanced -> Cron Jobs ($DESC)"
echo "Script: $PERSIST_CLEANUP"
echo "Log: /mnt/hub/alfa-ai/logs/alfa-docker-cleanup.log"
midclt call cronjob.query | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if "alfa docker" in (r.get("description") or "").lower():
        print("id=%s enabled=%s schedule=%s" % (r.get("id"), r.get("enabled"), r.get("schedule")))
        print("command=%s" % r.get("command"))
'
