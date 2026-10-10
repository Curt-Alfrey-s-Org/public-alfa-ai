#!/usr/bin/env bash
# Harden the native Mosquitto on apps, then open LAN :1883.
# Official: https://mosquitto.org/documentation/authentication-methods/
#           https://mosquitto.org/man/mosquitto_passwd-1.html
# Never prints MQTT_PASSWORD. Do not run victron scripts/deploy.sh on this host.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root (sudo)" >&2
  exit 1
fi

MQTT_USER="${MQTT_USER:-victron}"
PASSWD_FILE=/etc/mosquitto/passwd
WATCHDOG_ENV=/etc/mosquitto/watchdog.env
CONF_D=/etc/mosquitto/conf.d/00-lan-auth.conf
LEGACY_ANON=/etc/mosquitto/conf.d/00-allow-all.conf
PI5_HANDOFF=/tmp/pi5-mqtt.env
PW_TMP=$(mktemp /tmp/mqtt-pw.XXXXXX)
chmod 600 "$PW_TMP"

openssl rand -base64 24 | tr -d '\n/+' | head -c 32 > "$PW_TMP"
if [[ ! -s "$PW_TMP" ]]; then
  echo "failed to generate password" >&2
  rm -f "$PW_TMP"
  exit 1
fi

# -c overwrites; first (and only) user. -b is batch (password on argv; see man).
mosquitto_passwd -c -b "$PASSWD_FILE" "$MQTT_USER" "$(cat "$PW_TMP")"
chown mosquitto:mosquitto "$PASSWD_FILE"
chmod 640 "$PASSWD_FILE"

umask 077
{
  printf 'MQTT_USER=%s\n' "$MQTT_USER"
  printf 'MQTT_PASSWORD=%s\n' "$(cat "$PW_TMP")"
  printf 'MQTT_PORT=1883\n'
} > "$WATCHDOG_ENV"
chown root:root "$WATCHDOG_ENV"
chmod 600 "$WATCHDOG_ENV"

{
  printf 'MQTT_HOST=apps\n'
  printf 'MQTT_PORT=1883\n'
  printf 'MQTT_USERNAME=%s\n' "$MQTT_USER"
  printf 'MQTT_PASSWORD=%s\n' "$(cat "$PW_TMP")"
} > "$PI5_HANDOFF"
chmod 600 "$PI5_HANDOFF"
chown ansible:ansible "$PI5_HANDOFF" 2>/dev/null || true

cat > "$CONF_D" <<'EOF'
listener 1883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
EOF
chmod 644 "$CONF_D"
if [[ -f "$LEGACY_ANON" ]]; then
  mv "$LEGACY_ANON" "${LEGACY_ANON}.disabled"
fi

# Keep victron clone MQTT_* in sync (keys only; do not echo values).
update_dotenv_password() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  python3 - "$f" "$MQTT_USER" "$PW_TMP" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
user = sys.argv[2]
password = pathlib.Path(sys.argv[3]).read_text().strip()
text = path.read_text()
out = []
seen_host = seen_user = seen_pw = False
for raw in text.splitlines():
    if raw.startswith("MQTT_HOST="):
        out.append("MQTT_HOST=apps")
        seen_host = True
    elif raw.startswith("MQTT_USER=") or raw.startswith("MQTT_USERNAME="):
        key = raw.split("=", 1)[0]
        out.append(f"{key}={user}")
        seen_user = True
    elif raw.startswith("MQTT_PASSWORD="):
        out.append(f"MQTT_PASSWORD={password}")
        seen_pw = True
    else:
        out.append(raw)
if not seen_host:
    out.append("MQTT_HOST=apps")
if not seen_user:
    out.append(f"MQTT_USER={user}")
if not seen_pw:
    out.append(f"MQTT_PASSWORD={password}")
path.write_text("\n".join(out) + "\n")
PY
}
update_dotenv_password /home/operator/victron-ble2mqtt-integration/.env
update_dotenv_password /home/operator/victron-ble2mqtt-integration/ha-discovery.env

rm -f "$PW_TMP"

systemctl restart mosquitto
systemctl is-active --quiet mosquitto

set -a
# shellcheck disable=SC1091
source "$WATCHDOG_ENV"
set +a
if ! mosquitto_sub -h 127.0.0.1 -p 1883 -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
  -t '$SYS/broker/uptime' -C 1 -W 8 >/dev/null; then
  echo "mosquitto_sub auth probe failed" >&2
  exit 1
fi

if ufw status | grep -q "1883/tcp"; then
  echo "ufw already mentions 1883"
else
  ufw allow from orchestrator/24 to any port 1883 proto tcp comment "MQTT LAN pi4/pi5"
fi

echo "OK mosquitto auth + LAN 1883"
echo "pi5 handoff file: $PI5_HANDOFF (0600; copy then delete)"
