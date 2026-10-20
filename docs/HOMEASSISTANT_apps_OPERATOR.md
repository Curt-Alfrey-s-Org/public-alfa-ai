# Home Assistant + MQTT on `apps` (operator)

Canonical **MQTT broker** and **Home Assistant Container** live on the apps VM
**`apps` (`apps`)**, not on Pi4. Pi4 and Pi5 stay **BLE/USB collectors**
and publish over MQTT. This is a **Container** install (no add-ons), matching
the victron repo compose. Official types: [Home Assistant installation](https://www.home-assistant.io/installation/).

**Do not** run victron `scripts/deploy.sh` on `apps`. That installer defaults
`HOST_ROLE=pi4` (anything except `edge`), rewrites Mosquitto, runs
`systemctl restart docker` (all apps containers), and installs Dockge on `:5006`.
`apps` already has a Dockge **agent on `:5001`**.

## Target topology

```
Victron BLE (pi4 radio)  --MQTT-->  Mosquitto on apps:1883  -->  HA Container :8123
Sungold USB (pi4)        --MQTT-->         same
House BLE (Pi5 Theengs)  --MQTT-->         same
Solar-site BLE (Pi4 Theengs, off unless 2nd HCI) --MQTT-->     same
AdGuard DNS              stays on pi5 :53
Refoss EM16 (LAN UDP)    --------------->  HA Container :9989/udp
```

**Dashboards (what each radio sees):**

| Sidebar | Source | Notes |
|---------|--------|--------|
| **Pi4** | MQTT `sensor.victron_ble2mqtt_pi4_*` plus Theengs at the solar site | Victron shunts/MPPT stay on **Solar**. Solar-site Govee `CAAF6F` tiles stay **Unknown** until cells are replaced (2026-09-14). |
| **Pi5** | MQTT Theengs house BLE (toothbrushes, EcoFlow, …) | Only devices that Pi5 has heard. Oral-B advertises while brushing. |
| **Solar** | MQTT Victron + Theengs thermo + Sungold cart | Entity list. Not `victron_ble` on `apps`. HA labels `victron` / `sungold`. |
| **Energy** | Built-in Energy dashboard | Canonical solar / battery / load now + today. Sensors from victron package + `save_solar_plant_energy_prefs.py`. [SOLAR_HA_DASHBOARD.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SOLAR_HA_DASHBOARD.md). |
| **Refoss** | Official Refoss integration | LAN EM16 (this cluster: `orchestrator`). Not MQTT, not the Pis. Open **UDP 9989** from LAN or every card stays Unavailable. HA label `refoss`; device **Refoss Smart Energy Monitor, EM16**; dashboard headings are official channels **A1–C6**. |

Official Refoss: same LAN, socket broadcast, port **9989**. ufw on `apps`:

```bash
sudo ufw allow from orchestrator/24 to any port 9989 proto udp comment 'HA Refoss UDP'
```

When Pi4 is back: point `victron_ble2mqtt` at `apps`, then **stop HA and Mosquitto
on Pi4**. Do not run two Home Assistant instances.

## Ports and firewall

| Port | Service | Bind | ufw |
|------|---------|------|-----|
| **1883/tcp** | systemd Mosquitto (host) | `0.0.0.0` | LAN `orchestrator/24` only, **after** password auth |
| **8123/tcp** | HA Container (`network_mode: host`) | host stack | LAN `orchestrator/24`; optional `ufw allow in on 0 to any port 8123 proto tcp` |
| **1880/tcp** | Node-RED solar diagram (`nodered-solar`, host network) | host stack | LAN `orchestrator/24` only; see victron `docs/SOLAR_NODERED_OPERATOR.md` |
| **9989/udp** | HA Refoss discovery | host stack | LAN `orchestrator/24` ([Refoss occupies 9989](https://www.home-assistant.io/integrations/refoss/)) |

Host-network listeners are **not** published by Docker iptables; they hit ufw.
Official HA note: [Install on Linux](https://www.home-assistant.io/installation/linux/)
(`ufw allow 8123/tcp`). This cluster tightens that to LAN + `0` instead of
Anywhere. Official Docker: [packet filtering](https://docs.docker.com/engine/network/packet-filtering-firewalls/).
Official ufw interface form: [ufw(8)](https://manpages.ubuntu.com/manpages/noble/man8/ufw.8.html)
(`allow in on INTERFACE`).

### Energy (canonical)

**Canonical power-flow UI:** Home Assistant built-in **Energy**
([energy](https://www.home-assistant.io/docs/energy/),
[built-in dashboards](https://www.home-assistant.io/dashboards/dashboards/#home-assistant-built-in-dashboards)).
Plug in sensors with `bash scripts/install_solar_plant_ha.sh` (package + `energy:`)
then `python scripts/save_solar_plant_energy_prefs.py`. HA draws the cards.
Assign devices to [areas](https://www.home-assistant.io/docs/organizing/areas/) so
**Home** lists them. Sidebar **Solar** is the MQTT entity list. Leftover live
tiles (jumper, dump helpers including site confirm / 15 min on / 10 min cooldown, NWS) are on storage **Site solar** (`/site-solar`);
cards are movable. Do **not** register YAML Lovelace (`/solar-plant`).

**Editable solar topology diagram:** **Node-RED** on `apps` at **http://apps/** (tab **Solar plant diagram**). Node-RED **reads Home Assistant only** (REST); it does not replace HA sensors or Site solar tiles. Setup and edit rules: victron repo `docs/SOLAR_NODERED_OPERATOR.md` and `docs/SOLAR_DIAGRAM_POLICY.md`. Do **not** use Mermaid or SVG for site diagrams (retired).

**Site solar tiles:** device readings only (Victron, Sungold, EM16). Policy: victron `docs/SOLAR_DEVICE_SENSORS_ONLY.md`. Retired computed totals: `docs/SOLAR_CHARGE_VS_LOAD.md`.

Dump ON/OFF is `sim_dump_control.yaml` helpers
([DUMP_LOAD_HA_CONTROL.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/DUMP_LOAD_HA_CONTROL.md)).
alfa-ai `solar_dump.py` **observes** HA REST; it does **not** toggle dumps.

Companion: this instance has **no** `default_config:` (do **not** add it -- that
loads [Bluetooth](https://www.home-assistant.io/integrations/bluetooth/) and
[Cloud](https://www.home-assistant.io/integrations/cloud/)). Install script
appends official [Mobile App](https://www.home-assistant.io/integrations/mobile_app/)
`mobile_app:` only. Phone: Companion to `http://apps`; set **Energy**
as default on that device. Away = . Do **not** port-forward `:8123`.

The custom SVG proxy (`solar-flow.service`, `:8765`) is **retired**. After pull:
`bash scripts/uninstall_solar_flow.sh` on `apps`.

| Where | HA |
|-------|----|
| Home LAN | `http://apps` |
|  | `http://YOUR--NAME:8123` |

Do **not** commit the  name.

Mosquitto on `apps` is **2.0.x** (MQTT v5), required by
[HA MQTT](https://www.home-assistant.io/integrations/mqtt/). Auth:
[password files](https://mosquitto.org/documentation/authentication-methods/),
[`mosquitto_passwd`](https://mosquitto.org/man/mosquitto_passwd-1.html)
(`-c` overwrites the file; use once).

`mqtt-watchdog.timer` on `apps` probes `$SYS/broker/uptime` via
`/usr/local/bin/mqtt-watchdog.sh` and `/etc/mosquitto/watchdog.env`. Keep that
file in sync when rotating the password or the timer will restart Mosquitto
every minute.

## Home Assistant Container (Phase B)

- Image pin: `ghcr.io/home-assistant/home-assistant:2026.7.3` (`linux/amd64`).
- Hub-first: seed on `hub` as `home-assistant-2026.7.3.tar.gz`, then `docker load`
  on `apps`. Do not pull GHCR on the apps VM. See [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md).
- Config: `/opt/homeassistant`. Move any stale May 2026 tree aside before first
  start so onboarding is not the leftover login.
- Compose: victron `docker-compose.homeassistant.yml` only — **not**
  `stacksapps.yml` / `boot-all-stacks.sh`.
- After `up`: wait helper `wait-http.sh http://127.0.0.1:8123` (HA first boot is
  slow). See [WAIT_POLL_OPERATOR.md](WAIT_POLL_OPERATOR.md).
- MQTT integration: broker **`127.0.0.1:1883`** (same host as Mosquitto).
- Do **not** enable **Bluetooth**, **Govee Bluetooth**, **iBeacon**, or
  **victron_ble** on `apps`. Those integrations talk to a radio on the HA
  host ([Govee Bluetooth](https://www.home-assistant.io/integrations/govee_ble/),
  [Bluetooth](https://www.home-assistant.io/integrations/bluetooth/)). Victron
  Instant Readout stays on Pi4 via MQTT; house BLE stays on Pi5 Theengs.
  Disable leftover config entries and devices after copying `/opt/homeassistant`
  from Pi4 so Overview does not show Unavailable BLE entities.
- Solar / Pi4 dashboards must reference **MQTT** entity ids (`sensor.solar_controller_*`,
  `sensor.battery_1_*`, `sensor.battery_2_*`, `sensor.victron_ble2mqtt_pi4_*`,
  Theengs `sensor.thermo_hygrometer_caaf6f_*`), not `sensor.mppt_charger_*` /
  `sensor.smartshunt_*` from `victron_ble`.
- Ignore MQTT devices named `victron-ble2mqtt@web-sites` and `FAKE` (leftover
  from a collector run on `apps`). Disable those devices in the registry.
- **Display precision:** no hundredths on the dashboards. Current, voltage,
  power, energy (Wh/kWh), and power factor use tenths (`display_precision: 1`).
  MQTT Victron discovery sets
  [`suggested_display_precision`](https://www.home-assistant.io/integrations/sensor.mqtt/#suggested_display_precision)
  to `1` for A/V/W. Refoss has no MQTT discovery from this repo; set the user
  override
  [`options.sensor.display_precision`](https://developers.home-assistant.io/docs/api/websocket/)
  (and `suggested_display_precision`) to `1` so the frontend cannot fall back to
  the integration default of 2. Duration in minutes stays whole numbers.
  Always **stop** the `homeassistant` container before editing
  `/opt/homeassistant/.storage`
  ([Container common tasks](https://www.home-assistant.io/common-tasks/container/)).
  Hide Battery 1 midpoint tiles when Auxiliary Mode is `disabled` (stale
  leftover from the bad Instant Readout key).
- **Battery 1 accuracy:** HQ2239CQYT2 Instant Readout must use the **exact**
  32-hex advertisement key ([victron-ble](https://github.com/keshavdv/victron-ble),
  [HA Victron BLE](https://www.home-assistant.io/integrations/victron_ble/)).
  Pi4 `.env` had a 33-hex paste later trimmed to 32; that value decrypted as
  garbage. The working key was already on Pi4 in the old HA
  `victron_ble` config entry (`access_token` for SmartShunt HQ2239CQYT2), and
  matched MPPT / Battery 2 on the ~24 V bus after it was copied into
  `ADVKEY_BATTERY_1`. MPPT and Battery 2 keys in `.env` already matched those
  HA entries. Do not invent a 32-char window of a longer paste.
- **MQTT Solar sidebar:** entity list from discovery. Duplicate charge-state /
  voltage / power cards were leftovers from the `victron_ble` → MQTT retarget.
  **Sungold SPH302480A** (Pi4 USB sidecar) uses Home Assistant
  [Labels](https://www.home-assistant.io/docs/organizing/labels/)
  (`sungold`) on the MQTT device and entities, and a **Sungold**
  [sections](https://www.home-assistant.io/dashboards/sections/) heading
  with [tile](https://www.home-assistant.io/dashboards/tile/) cards
  ([heading](https://www.home-assistant.io/dashboards/heading/)).
  MQTT discovery `name` strings follow the SPH302480A LCD §4.1 / fault §6.2
  wording ([SunGoldPower product / manual](https://sungoldpower.com/products/3000w-24v-solar-inverter-charger)).
  Lovelace tiles must use **live** `entity_id`s whose MQTT `unique_id` starts
  with `sungold_sph302480a-` (keys such as `pv1/voltage`) and
  `name: {type: entity}` so tiles show LCD names, not `Sungold S...`
  ([card naming](https://www.home-assistant.io/dashboards/naming/)).
  USB timeouts keep polling; they must not skip the register for an hour and
  must not publish an empty MQTT discovery payload
  ([MQTT discovery](https://www.home-assistant.io/integrations/mqtt/#discovery-messages)).
  **Victron MQTT** Instant Readout names follow VictronConnect
  ([SmartShunt operation](https://www.victronenergy.com/media/pg/SmartShunt/en/operation.html),
  [BlueSolar MPPT 75/15 monitoring](https://www.victronenergy.com/media/pg/Manual_BlueSolar_MPPT_75-10_up_to_100-20/en/monitoring.html)).
  MPPT ads do **not** include solar voltage or solar current (VictronConnect
  7.3.1 while connected; VE.Direct `VPV` needs the VE.Direct port -- this site
  uses that port for the BLE dongle). Field table: victron
  [DEVICES.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/DEVICES.md).
  Solar heading already shows every Instant Readout live field; do not add tiles
  for PV volts.
  Pi4 compose sets `PYTHONSAFEPATH=1` so the bind-mounted override `mqtt.py` is
  what publishes those names ([PYTHONSAFEPATH](https://docs.python.org/3/using/cmdline.html#envvar-PYTHONSAFEPATH)).
  Solar Victron tiles stay **Unknown** until Pi4 publishes MQTT **state** (config
  retain is not enough — [MQTT sensor](https://www.home-assistant.io/integrations/sensor.mqtt/)).
  The sidecar must start BLE (`BLE scanner started` in `victron_ble2mqtt` logs),
  republish unchanged Instant Readout on the publish throttle, and retain device
  state. Container `healthy` requires BLE scanner start (`BLE_SCANNER_OK_FILE`),
  a recent Instant Readout publish heartbeat (`BLE_PUBLISH_HEARTBEAT_FILE`, default
  max age 600s), and the system-info heartbeat (event loop + MQTT)
  ([Compose healthcheck](https://docs.docker.com/reference/compose-file/services/#healthcheck)).
  Autoheal restarts only after Engine `unhealthy`; `restart: unless-stopped` does
  not ([restart policy](https://docs.docker.com/engine/containers/start-containers-automatically/)).
  Do not add `expire_after` on retained Victron MQTT state
  ([MQTT sensor retain](https://www.home-assistant.io/integrations/sensor.mqtt/)).
  HA label `victron`; Site **Solar** shows the paired **KU BlueSolar MPPT
  75/15** (`sensor.solar_controller_*`). T2 **SmartSolar 100/50** (2s3p) is not
  in HA until its Instant Readout advertisement key is paired
  ([SmartSolar 100/30-100/50](https://www.victronenergy.com/solar-charge-controllers/smartsolar-100-30-100-50));
  second KU 75/15 stays silent until its key exists. PWM removed 2026-10-02.
  BlueSolar monitoring fields still follow
  [BlueSolar MPPT 75/15 monitoring](https://www.victronenergy.com/media/pg/Manual_BlueSolar_MPPT_75-10_up_to_100-20/en/monitoring.html)
  (not leftover `Mppt charger`). SmartShunt serial headings stay the VictronConnect product
  ids. **Refoss EM16** channel names A1-C6 and
  `{channel} current/power/...` already match the official
  [Refoss integration](https://www.home-assistant.io/integrations/refoss/)
  and [EM16 product](https://refoss.net/collections/smart-energy-monitor/products/refoss-smart-energy-monitor-em16).
  HA label `refoss`; device name **Refoss Smart Energy Monitor, EM16**; Refoss
  dashboard sections are one official channel per heading.
  Apply with HA **stopped**:
  `sudo python3 /home/operator/victron-ble2mqtt-integration/scripts/ha_label_sungold_solar.py`
  then
  `sudo python3 /home/operator/victron-ble2mqtt-integration/scripts/ha_label_victron_refoss.py`
  then `docker start homeassistant` and
  `bash /home/operator/alfa-ai/deploy/cluster-members/_common/wait-http.sh http://127.0.0.1:8123 120`.
- Do **not** add HomeKit Device or EcoNet until an official Pi4 backup exists
  (or you accept re-pairing). [HomeKit Device](https://www.home-assistant.io/integrations/homekit_controller)
  is one controller. Official migrate is **backup then restore** (overwrites),
  not copy/merge: [common tasks](https://www.home-assistant.io/common-tasks/general/).

## Autoheal on `apps` (HTTP-unhealthy Home Assistant)

`docker-compose.homeassistant.yml` defines a Compose
[healthcheck](https://docs.docker.com/reference/compose-file/services/#healthcheck)
(`curl -fsS http://localhost:8123/`). Docker
[`restart: unless-stopped`](https://docs.docker.com/engine/containers/start-containers-automatically/)
restarts **exited** containers only; a live but HTTP-unhealthy `homeassistant`
process is not restarted without a sidecar.

The victron stack labels `homeassistant` with **`autoheal: "true"`** (label
**name** `autoheal`, value `"true"`). [willfarrell/autoheal](https://github.com/willfarrell/docker-autoheal)
polls Engine health and restarts matching containers when status is
**`unhealthy`**. Set **`AUTOHEAL_CONTAINER_LABEL=autoheal`** (the label name,
not `autoheal=true`) per the
[entrypoint filter](https://github.com/willfarrell/docker-autoheal/blob/master/docker-entrypoint).

**Do not** change the HA healthcheck to MQTT broker uptime, unauthenticated
MQTT sensor state, or authenticated Home Assistant REST (`GET /api/` requires a
token — [REST API](https://developers.home-assistant.io/docs/api/rest/)). Do
**not** add `expire_after` on retained MQTT sensor state.

**Do not** run victron `scripts/deploy.sh` on `apps` (Pi4 installer, Mosquitto
rewrite, `systemctl restart docker`). Start autoheal with compose only — no
`--remove-orphans`, do not recreate `homeassistant` unless you are changing HA
itself.

Repo on `apps`: `/home/operator/victron-ble2mqtt-integration`.

**Step 1 — From `apps` (`ansible`):** sync the victron clone (pull gets the
correct `AUTOHEAL_CONTAINER_LABEL` and HA label):

```bash
cd /home/operator/victron-ble2mqtt-integration && git pull --ff-only origin main
```

**Step 2 — From `apps` (`ansible`):** start autoheal if `docker ps` shows no
`autoheal` container (does not touch `homeassistant`):

```bash
cd /home/operator/victron-ble2mqtt-integration && docker compose -f docker-compose.autoheal.yml up -d
```

**Verify — From `apps` (`ansible`):**

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | egrep 'autoheal|homeassistant'
```

Expect `autoheal` **Up** and `homeassistant` unchanged (still **Up**, ideally
**healthy**). Optional: `docker logs --tail 20 autoheal`.

Pi4/Pi5 `deploy.sh` already starts autoheal on those hosts; `apps` needs this
one-time compose step because HA was brought up with
`docker-compose.homeassistant.yml` only.

## First backup after migrate

This is a **Container** install. Create a local backup with the official
Backup integration ([`backup.create`](https://www.home-assistant.io/actions/backup.create/),
[common tasks](https://www.home-assistant.io/common-tasks/general/)):

1. Open HA → **Settings → System → Backups → Backup now** (manual), or
   **Settings → Tools → Actions** → **Create backup**.
2. Wait until Settings → System → Backups lists the new file.
3. Download a copy off `apps`. `/opt/homeassistant/backups` is the local store.

`ha backups` is Home Assistant OS / Supervisor only — do not use it here.
Do not `tar` `/opt/homeassistant` while the container is running (SQLite).

## Pi5 Theengs

Live file: `hosts/pi5/mqtt.env` (gitignored). `MQTT_HOST=apps`.
`scripts/write_pi5_mqtt_env.sh` fallback broker is `apps`. Do not regenerate
that file with the old default `solar-broker`.

LWT `home/TheengsGateway-pi5/LWT` is MQTT availability
([Theengs `-Lt`](https://gateway.theengs.io/use/use.html)), not Docker liveness
and not proof of `BTtoMQTT` publishes. If logs show `Failed to send message`
or MQTT [keep-alive timeout](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html) (MQTT v5 §3.1.2.10),
recreate **only** `theengs-gateway` on Pi5:

```bash
cd /home/operator/victron-ble2mqtt-integration/hosts/pi5 && sudo docker compose -f docker-compose.theengs.yml up -d --force-recreate theengs-gateway
```

Do not add a Theengs HEALTHCHECK. Do not pass `--remove-orphans`.

## Pi4 Theengs (off by default)

Pi4 onboard HCI is exclusive to `victron_ble2mqtt`. BlueZ one
`StartDiscovery` session per client per adapter
([org.bluez.Adapter](https://manpages.ubuntu.com/manpages/noble/man5/org.bluez.Adapter.5.html)).
Leave `ENABLE_PI4_THEENGS=0`. Deploy on Pi4 tears down leftover
`pi4-theengs-gateway` via Compose `--profile solar-theengs down`
([profiles](https://docs.docker.com/compose/how-tos/profiles/)). Solar-site
Govee `CAAF6F` Unknown tiles are dead cells (2026-09-14), not a frozen
Victron path. Do not start Pi4 Theengs on `hci0`.

## alfa-ai brain control (REST, not Lovelace scrape)

Do not point automations or agents at `/dashboard-solar/0` as a data source.
The brain on `hub` uses the official REST API ([REST API](https://developers.home-assistant.io/docs/api/rest/))
with a long-lived token. Keep the token as gitignored
`deploy/secrets/home-assistant/long-lived.token` (see
[HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md)
token table). Workstation copy: `orchestrator`
`C:/Users/operator\alfa-ai\deploy\secrets\home-assistant\long-lived.token`.
Not in `host105-ai.env`. Not `ssh operator@orchestrator`.
Operator Settings and allowlist:
[HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md).

**Simulated dump-load plugs (opt-in, not MQTT):** six fake A/C loads for alfa-ai dump load
testing (`switch.sim_ac_plug_1` ... `_6`). HA YAML package (template switch +
`input_boolean` internal); allowlist switches only, not `input_boolean.*`. Install
after `git pull` in this repo:

```bash
cd /home/operator/victron-ble2mqtt-integration && bash scripts/install_sim_dump_plugs_ha.sh
```

Details: victron [docs/SIM_DUMP_PLUGS.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SIM_DUMP_PLUGS.md).
Brain kill switch remains `ALFA_AI_HOME_ASSISTANT_ENABLED=0` on `hub` (see brain doc).

HA Container healthcheck stays unauthenticated `GET /` on loopback. Do not
put the long-lived token in the compose healthcheck.

## Related

- [PI4_VICTRON_OPERATOR.md](PI4_VICTRON_OPERATOR.md), [PI5_OPERATOR.md](PI5_OPERATOR.md)
- [RELATED_VICTRON_HOMEAUTO.md](RELATED_VICTRON_HOMEAUTO.md)
- [HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md)
- victron [docs/SOLAR_POWER_BALANCE.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SOLAR_POWER_BALANCE.md) -- T2 vs KU; do not add B2; 10-11 Sep A3 = trailer; 15 Sep A3 = Sungold AC-in
- [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md)
- victron `docs/PI5_HOUSE_EDGE.md`
