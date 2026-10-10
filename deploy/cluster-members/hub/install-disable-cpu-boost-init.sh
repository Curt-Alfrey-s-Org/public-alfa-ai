#!/usr/bin/env bash
# Register disable-cpu-boost.sh as a hub Init/Shutdown Script (Post Init).
#
# Survives hub upgrades: script lives on the HDD pool; midclt entry runs it
# at POSTINIT each boot. See DOCKGE_111_OPERATOR.md (CPU boost disable).
#
# Usage (on hub as operator):
#   bash deploy/cluster-members/hub/install-disable-cpu-boost-init.sh
#
# Undo:
#   bash deploy/cluster-members/hub/install-disable-cpu-boost-init.sh --uninstall
#   echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
REPO_SCRIPT="$REPO_DIR/deploy/cluster-members/hub/disable-cpu-boost.sh"
PERSIST_DIR="/mnt/hub/alfa-ai/scripts"
PERSIST_SCRIPT="$PERSIST_DIR/disable-cpu-boost.sh"
COMMENT="alfa disable cpu boost 4600mhz (7900X thermal)"
RUN_CMD="sudo bash $PERSIST_SCRIPT"

if [[ -f "$REPO_SCRIPT" ]]; then
  SOURCE_SCRIPT="$REPO_SCRIPT"
elif [[ -f "$SCRIPT_DIR/disable-cpu-boost.sh" ]]; then
  SOURCE_SCRIPT="$SCRIPT_DIR/disable-cpu-boost.sh"
else
  echo "ERROR: missing disable-cpu-boost.sh (repo or script dir)" >&2
  exit 1
fi

sudo mkdir -p "$PERSIST_DIR"
sudo install -m 0755 "$SOURCE_SCRIPT" "$PERSIST_SCRIPT"
DISABLE_SCRIPT="$PERSIST_SCRIPT"

if [[ "${1:-}" == "--uninstall" ]]; then
  if ! command -v midclt >/dev/null 2>&1; then
    echo "ERROR: midclt not found; remove Init/Shutdown Script manually in hub UI" >&2
    exit 1
  fi
  mapfile -t IDS < <(midclt call initshutdownscript.query 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
needle = "alfa disable cpu boost"
for row in data:
    blob = json.dumps(row).lower()
    if needle in blob:
        print(row.get("id", ""))
' || true)
  if [[ ${#IDS[@]} -eq 0 ]]; then
    echo "No init script matched comment; nothing to remove."
    exit 0
  fi
  for id in "${IDS[@]}"; do
    [[ -n "$id" ]] || continue
    midclt call initshutdownscript.delete "$id"
    echo "Removed initshutdownscript id=$id"
  done
  echo "Re-enable boost: echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost"
  exit 0
fi

echo "== disable-cpu-boost Post Init registration =="

# Retire MHz cap Post Init if present (conflicts with boost-off thermal policy).
UNINSTALL_CAP="$REPO_DIR/deploy/cluster-members/hub/install-cap-cpu-max-freq-init.sh"
if [[ -f "$UNINSTALL_CAP" ]]; then
  echo "Removing cap-cpu-max-freq Post Init (if any)..."
  bash "$UNINSTALL_CAP" --uninstall || true
fi

if command -v midclt >/dev/null 2>&1; then
  EXISTING="$(midclt call initshutdownscript.query 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)
needle = "alfa disable cpu boost"
for row in data:
    if needle in json.dumps(row).lower():
        print(row.get("id", ""))
        break
' || true)"
  if [[ -n "$EXISTING" ]]; then
    echo "Init script already registered (id=$EXISTING); updating command to use sudo."
    midclt call initshutdownscript.update "$EXISTING" "$(python3 - <<PY
import json
print(json.dumps({
    "type": "COMMAND",
    "when": "POSTINIT",
    "enabled": True,
    "comment": "$COMMENT",
    "command": "$RUN_CMD",
    "timeout": 180,
}))
PY
)"
    echo "Updated Post Init command via midclt (id=$EXISTING)."
  else
    midclt call initshutdownscript.create "$(python3 - <<PY
import json
print(json.dumps({
    "type": "COMMAND",
    "when": "POSTINIT",
    "enabled": True,
    "comment": "$COMMENT",
    "command": "$RUN_CMD",
    "timeout": 180,
}))
PY
)"
    echo "Registered Post Init command via midclt."
  fi
else
  echo "midclt not available; add manually in hub UI:"
  echo "  System Settings -> Advanced -> Init/Shutdown Scripts -> Add"
  echo "    Type: Command"
  echo "    When: Post Init"
  echo "    Enabled: Yes"
  echo "    Timeout: 180"
  echo "    Command: $RUN_CMD"
fi

echo ""
echo "Applying now (no reboot required):"
sudo bash "$DISABLE_SCRIPT"

echo ""
echo "Verify (use policy0 on amd_pstate; cpu0 may show a stale mirror):"
echo "  cat /sys/devices/system/cpu/cpufreq/boost   # expect 0"
echo "  cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq   # expect 4600000"
echo "  grep MHz /proc/cpuinfo | head -4"
