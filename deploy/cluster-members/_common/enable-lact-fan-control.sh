#!/usr/bin/env bash
# Enable LACT custom fan curves on every GPU in /etc/lact/config.yaml.
#
# Official: https://github.com/ilya-zlobintsev/LACT/blob/master/docs/CONFIG.md
# Thermals tab in lact gui --tcp-address HOST:12853 after this runs.
#
# Usage:
#   sudo bash deploy/cluster-members/_common/enable-lact-fan-control.sh

set -euo pipefail

CONFIG_LIVE="/etc/lact/config.yaml"

if [[ "${EUID:-}" -ne 0 ]]; then
	echo "ERROR: run as root: sudo bash $0" >&2
	exit 1
fi

if [[ ! -f "$CONFIG_LIVE" ]]; then
	echo "ERROR: missing $CONFIG_LIVE (run install-lact-headless.sh first)" >&2
	exit 1
fi

python3 <<'PY'
import re
from pathlib import Path

config_path = Path("/etc/lact/config.yaml")
text = config_path.read_text()

fan_block = """    fan_control_enabled: true
    fan_control_settings:
      mode: curve
      static_speed: 1.0
      temperature_key: edge
      interval_ms: 500
      curve:
        40: 0.30
        50: 0.45
        60: 0.60
        70: 0.80
        80: 1.0
      spindown_delay_ms: 3000
      change_threshold: 2
      auto_threshold: 50
"""

if "fan_control_settings:" in text and "fan_control_enabled: true" in text:
    print("fan control already enabled -- skipping (keeps operator GUI curves)")
    raise SystemExit(0)
else:
    new_text, count = re.subn(
        r"    fan_control_enabled: false\n",
        fan_block + "\n",
        text,
    )
    if count == 0:
        raise SystemExit("no fan_control_enabled: false entries found to update")
    config_path.write_text(new_text)
    print(f"enabled fan control on {count} GPU(s)")

PY

echo "OK: LACT will reload GPU settings from $CONFIG_LIVE (no lactd restart required)"
echo "Open LACT -> Thermals tab to adjust the curve, then Apply."
