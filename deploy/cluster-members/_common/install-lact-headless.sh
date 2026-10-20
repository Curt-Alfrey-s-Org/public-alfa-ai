#!/usr/bin/env bash
set -euo pipefail

# Install LACT headless v0.10.1 on Ubuntu 26.04 GPU hosts (inference / pool-opt-in only).
#
# Official install: https://github.com/ilya-zlobintsev/LACT#installation
# Release deb: https://github.com/ilya-zlobintsev/LACT/releases/download/v0.10.1/lact-headless-0.10.1-0.amd64.ubuntu-2604.deb
# systemd: https://github.com/ilya-zlobintsev/LACT#usage
# Config: https://github.com/ilya-zlobintsev/LACT/blob/master/docs/CONFIG.md
# Remote TCP port 12853 (no auth): https://github.com/ilya-zlobintsev/LACT#remote-management
# nvidia-smi preflight: https://docs.nvidia.com/deploy/nvidia-smi/index.html
# dpkg local .deb: https://manpages.debian.org/bookworm/dpkg/dpkg.1.en.html
#
# Usage:
#   sudo bash deploy/cluster-members/_common/install-lact-headless.sh

LACT_VERSION="0.10.1"
LACT_DEB_NAME="lact-headless-${LACT_VERSION}-0.amd64.ubuntu-2604.deb"
LACT_DEB_URL="https://github.com/ilya-zlobintsev/LACT/releases/download/v${LACT_VERSION}/${LACT_DEB_NAME}"
LACT_TCP_PORT="12853"
LAN_CIDR="${ALFA_LAN_CIDR:-orchestrator/24}"
CONFIG_LIVE="/etc/lact/config.yaml"

FORBIDDEN_IPS=("orchestrator" "apps" "hub")
HOST_148="orchestrator"
HOST_100="orchestrator"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LACT_CONFIG_DIR="$SCRIPT_DIR/lact"

fail_lact() {
	local msg="${1:-install failed}"
	echo "ERROR: $msg" >&2
	if command -v systemctl >/dev/null 2>&1; then
		journalctl -u lactd --no-pager -n 40 2>/dev/null || true
	fi
	exit 1
}

require_root() {
	if [[ "${EUID:-}" -ne 0 ]]; then
		echo "ERROR: run as root: sudo bash $0" >&2
		exit 1
	fi
}

detect_lan_ips() {
	local ips=""
	if command -v hostname >/dev/null 2>&1; then
		ips="$(hostname -I 2>/dev/null || true)"
	fi
	if [[ -z "${ips// }" ]] && command -v ip >/dev/null 2>&1; then
		ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
	fi
	echo "$ips"
}

host_has_ip() {
	local needle="$1"
	local ips="$2"
	for ip in $ips; do
		[[ "$ip" == "$needle" ]] && return 0
	done
	return 1
}

echo "== install LACT headless v${LACT_VERSION} =="
echo "  Repo: $REPO_ROOT"
echo ""

require_root

if ! command -v nvidia-smi >/dev/null 2>&1; then
	fail_lact "nvidia-smi not found (GPU host required)"
fi
if ! nvidia-smi >/dev/null 2>&1; then
	fail_lact "nvidia-smi failed (driver not working)"
fi

if [[ -f /etc/os-release ]]; then
	# shellcheck disable=SC1091
	source /etc/os-release
	if [[ "${ID:-}" != "ubuntu" ]]; then
		echo "WARN: expected Ubuntu; found ID=${ID:-unknown}"
	elif [[ "${VERSION_ID:-}" != "26.04" ]]; then
		echo "WARN: expected Ubuntu 26.04; found VERSION_ID=${VERSION_ID:-unknown} (continuing)"
	fi
else
	echo "WARN: /etc/os-release missing; cannot verify Ubuntu 26.04"
fi

LAN_IPS="$(detect_lan_ips)"
if [[ -z "${LAN_IPS// }" ]]; then
	fail_lact "could not detect LAN IPv4 addresses (hostname -I / ip -4 addr)"
fi
echo "  LAN IPs: $LAN_IPS"

for forbidden in "${FORBIDDEN_IPS[@]}"; do
	if host_has_ip "$forbidden" "$LAN_IPS"; then
		fail_lact "host $forbidden is excluded from LACT install (orchestrator Windows / apps CPU-only / hub hub)"
	fi
done

TARGET_IP=""
EXAMPLE_CONFIG=""
if host_has_ip "$HOST_148" "$LAN_IPS"; then
	TARGET_IP="$HOST_148"
	EXAMPLE_CONFIG="$LACT_CONFIG_DIR/configinference.yaml.example"
elif host_has_ip "$HOST_100" "$LAN_IPS"; then
	TARGET_IP="$HOST_100"
	EXAMPLE_CONFIG="$LACT_CONFIG_DIR/configpool-opt-in.yaml.example"
else
	fail_lact "unsupported host (need LAN IP $HOST_148 or $HOST_100; got: $LAN_IPS)"
fi

if [[ ! -f "$EXAMPLE_CONFIG" ]]; then
	fail_lact "example config missing: $EXAMPLE_CONFIG"
fi

echo "  Target: $TARGET_IP"
echo "  Config: $EXAMPLE_CONFIG"
echo ""

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
DEB_PATH="$TMP_DIR/$LACT_DEB_NAME"

echo "== download $LACT_DEB_NAME =="
if ! curl -fL --max-time 120 -o "$DEB_PATH" "$LACT_DEB_URL"; then
	fail_lact "curl download failed: $LACT_DEB_URL"
fi

DEB_SIZE="$(stat -c%s "$DEB_PATH" 2>/dev/null || wc -c <"$DEB_PATH")"
if [[ "${DEB_SIZE:-0}" -le 1048576 ]]; then
	fail_lact "downloaded .deb too small (${DEB_SIZE} bytes); expected > 1 MB"
fi
echo "  downloaded: $DEB_PATH (${DEB_SIZE} bytes)"

echo ""
echo "== install package (dpkg) =="
if ! dpkg -i "$DEB_PATH"; then
	echo "  dpkg reported missing dependencies; running apt-get install -f"
	apt-get install -y -f
	dpkg -i "$DEB_PATH" || fail_lact "dpkg -i failed after apt-get install -f"
fi

if ! command -v lact >/dev/null 2>&1; then
	fail_lact "lact binary not found after package install"
fi

echo ""
echo "== install config =="
mkdir -p /etc/lact
if [[ -f "$CONFIG_LIVE" ]]; then
	BACKUP="${CONFIG_LIVE}.bak.$(date +%Y%m%d-%H%M%S)"
	cp -a "$CONFIG_LIVE" "$BACKUP"
	echo "  backed up live config to $BACKUP"
fi
cp "$EXAMPLE_CONFIG" "$CONFIG_LIVE"
echo "  installed $CONFIG_LIVE from example"

echo ""
echo "== enable lactd =="
systemctl enable --now lactd || fail_lact "systemctl enable --now lactd failed"

sleep 2

echo ""
echo "== remap GPU IDs (if needed) =="
LIST_GPUS_OUT="$(lact cli list-gpus 2>/dev/null || true)"
if [[ -z "$LIST_GPUS_OUT" ]]; then
	fail_lact "lact cli list-gpus returned no output"
fi
echo "$LIST_GPUS_OUT"

if command -v python3 >/dev/null 2>&1; then
	python3 - "$CONFIG_LIVE" "$EXAMPLE_CONFIG" "$LIST_GPUS_OUT" <<'PY' || fail_lact "GPU ID remap failed"
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
example_path = Path(sys.argv[2])
list_gpus = sys.argv[3]

# Presets keyed by model substring (order matters: 5060 before 3060).
PRESET_ORDER = [
    ("5060", {"gpu_clock_offsets": {0: 150}, "mem_clock_offsets": {0: 400}, "power_cap": 155.0, "power_mizer_mode": "PreferMaximumPerformance"}),
    ("3060", {"gpu_clock_offsets": {0: 150}, "mem_clock_offsets": {0: 400}, "power_cap": 170.0, "power_mizer_mode": "PreferMaximumPerformance"}),
    ("1660", {"gpu_clock_offsets": {0: 100}, "mem_clock_offsets": {0: 400}, "power_cap": 140.0, "power_mizer_mode": "PreferMaximumPerformance"}),
]

def preset_for_name(name: str):
    upper = name.upper()
    for key, preset in PRESET_ORDER:
        if key in upper:
            return preset
    return None

def parse_example_gpu_ids(text: str):
    ids = []
    for line in text.splitlines():
        m = re.match(r"^  ([0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9A-Fa-f]):", line)
        if m:
            ids.append(m.group(1))
    return ids

def parse_live_gpus(text: str):
    live = []
    for line in text.splitlines():
        m = re.match(r"^\s*\d+:\s+([^\s]+)\s+\(([^)]+)\)", line.strip())
        if m:
            live.append((m.group(1), m.group(2)))
    return live

def yaml_scalar(v):
    if isinstance(v, str):
        return v
    if isinstance(v, float) and v == int(v):
        return str(int(v))
    return str(v)

def render_offsets(key, mapping):
    lines = [f"    {key}:"]
    for k, v in sorted(mapping.items()):
        lines.append(f"      {k}: {yaml_scalar(v)}")
    return lines

def render_gpu_block(gpu_id, preset):
    lines = [f"  {gpu_id}:"]
    lines.extend(render_offsets("gpu_clock_offsets", preset["gpu_clock_offsets"]))
    lines.extend(render_offsets("mem_clock_offsets", preset["mem_clock_offsets"]))
    lines.append(f"    power_cap: {yaml_scalar(preset['power_cap'])}")
    lines.append(f"    power_mizer_mode: {preset['power_mizer_mode']}")
    return lines

example_text = example_path.read_text(encoding="utf-8")
config_text = config_path.read_text(encoding="utf-8")
example_ids = set(parse_example_gpu_ids(example_text))
live_gpus = parse_live_gpus(list_gpus)
live_ids = {gid for gid, _ in live_gpus}

if live_ids == example_ids:
    print("  GPU IDs match example; no remap needed")
    sys.exit(0)

if not live_gpus:
    print("ERROR: could not parse lact cli list-gpus", file=sys.stderr)
    sys.exit(1)

daemon_lines = []
in_daemon = False
for line in config_text.splitlines():
    if line.startswith("daemon:"):
        in_daemon = True
    elif in_daemon and line.startswith("gpus:"):
        in_daemon = False
        break
    if in_daemon:
        daemon_lines.append(line)

if not daemon_lines:
    print("ERROR: daemon section missing in config", file=sys.stderr)
    sys.exit(1)

new_lines = list(daemon_lines)
new_lines.append("")
new_lines.append("gpus:")

matched = 0
for gpu_id, name in live_gpus:
    preset = preset_for_name(name)
    if preset is None:
        print(f"WARN: no preset for GPU {gpu_id} ({name}); skipping", file=sys.stderr)
        continue
    new_lines.extend(render_gpu_block(gpu_id, preset))
    matched += 1

if matched == 0:
    print("ERROR: no live GPUs matched ALFa presets", file=sys.stderr)
    sys.exit(1)

config_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
print(f"  remapped {matched} GPU(s) in {config_path}")
PY
else
	echo "  WARN: python3 missing; skipping GPU ID remap"
fi

echo ""
echo "== restart lactd =="
systemctl restart lactd || fail_lact "systemctl restart lactd failed"
sleep 2

echo ""
echo "== verify lactd =="
if [[ "$(systemctl is-active lactd 2>/dev/null || true)" != "active" ]]; then
	fail_lact "lactd is not active"
fi
echo "  systemctl is-active lactd: active"

echo ""
echo "== verify list-gpus =="
lact cli list-gpus || fail_lact "lact cli list-gpus failed"

echo ""
echo "== verify TCP bind on ${TARGET_IP}:${LACT_TCP_PORT} =="
if ! command -v ss >/dev/null 2>&1; then
	echo "  WARN: ss not found; skip TCP bind check"
else
	SS_OUT="$(ss -ltnH 2>/dev/null || true)"
	if echo "$SS_OUT" | grep -qE "${TARGET_IP}:${LACT_TCP_PORT}\b"; then
		echo "  OK: listening on ${TARGET_IP}:${LACT_TCP_PORT}"
	elif echo "$SS_OUT" | grep -qE "0\\.0\\.0\\.0:${LACT_TCP_PORT}\b|\\[::\\]:${LACT_TCP_PORT}\\b"; then
		fail_lact "LACT TCP bound to all interfaces; expected ${TARGET_IP}:${LACT_TCP_PORT} only"
	else
		fail_lact "LACT TCP ${TARGET_IP}:${LACT_TCP_PORT} not found in ss -ltn"
	fi
fi

echo ""
echo "== optional UFW =="
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qiE 'Status: active'; then
	if ufw status numbered 2>/dev/null | grep -qE "${LACT_TCP_PORT}/tcp.*LACT"; then
		echo "  ufw OK: port ${LACT_TCP_PORT} (LACT)"
	else
		ufw allow from "$LAN_CIDR" to any port "$LACT_TCP_PORT" proto tcp comment 'LACT LAN only' || true
		echo "  ufw allow: port ${LACT_TCP_PORT} from ${LAN_CIDR}"
	fi
	ufw reload 2>/dev/null || true
else
	echo "  ufw inactive or missing; skip (do not enable ufw)"
fi

echo ""
echo "install-lact-headless.sh OK"
echo "  Remote GUI: lact gui --tcp-address ${TARGET_IP}:${LACT_TCP_PORT}"
echo "  Config: ${CONFIG_LIVE}"
