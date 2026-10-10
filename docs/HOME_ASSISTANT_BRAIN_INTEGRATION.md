# Home Assistant brain integration (solar dump load / diversion control)

**Hosts:** Brain API on **`hub`**. Home Assistant Container on **`apps:8123`**.
MQTT telemetry (Victron / Sungold / Theengs) already lands in HA; this doc is the
**alfa-ai control plane**, not a second dashboard scraper.

**Operator policy (2026-09-15):** alfa-ai may **monitor** HA entity states and
**control allowlisted smart devices** according to operator **Settings**
(`ai_settings`). It does **not** write application source on this path. The
15-minute dump-load loop is **deterministic program code** (thresholds + allowlist).
The LLM is not on the timer. **Dump does not need 7B or 27B** (see
[Dump vs 7B / 27B](#dump-vs-7b--27b-independent)).

Dump / diversion loads follow the Morningstar TriStar diversion pattern (absorb
MPPT surplus):
[Morningstar diversion manual](https://www.morningstarcorp.com/wp-content/uploads/technical-doc-diversion-manual-en.pdf).
**16 Sep topology:** dump loads are fed from **Sungold SPH302480A AC output**, not
KU Renogy trailer house load on EM16 A3 (A3 meters Sungold AC-in on the trailer
outlet). See victron [SOLAR_POWER_BALANCE.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SOLAR_POWER_BALANCE.md).

Official HA manuals (RULE #1):

- REST API: [developers.home-assistant.io/docs/api/rest](https://developers.home-assistant.io/docs/api/rest/)
- Long-lived tokens: [Authentication](https://www.home-assistant.io/docs/authentication/) and
  [Auth API](https://developers.home-assistant.io/docs/auth_api/#long-lived-access-token)
- Entity id format `domain.object_id`: [State object](https://www.home-assistant.io/docs/configuration/state_object/)
- Entity registry / customize: [customizing devices](https://www.home-assistant.io/docs/configuration/customizing-devices/)
- Switch actions: [switch.turn_on](https://www.home-assistant.io/actions/switch.turn_on/) /
  [switch.turn_off](https://www.home-assistant.io/actions/switch.turn_off/)
- FastAPI lifespan (brain ticker): [Lifespan events](https://fastapi.tiangolo.com/advanced/events/)

Do **not** scrape Lovelace (`/dashboard-solar/0`). That URL is the frontend login
flow, not a machine API. Scheduled HTML scrape is forbidden
([no-automatic-scraping](../.cursor/rules/no-automatic-scraping.mdc)).
The brain also does **not** scrape Lovelace or any retired SVG
page. Those surfaces are **human-only**. Machine numbers come from HA REST `state`
strings via `GET /api/states` ([REST API](https://developers.home-assistant.io/docs/api/rest/);
[state object](https://www.home-assistant.io/docs/configuration/state_object/)
-- `state.state` is always a string). `float()` keeps an optional `+` / `-`
([built-in `float`](https://docs.python.org/3/library/functions.html#float)).

**Display vs program path:** canonical operator view is HA built-in **Energy**
(`/energy`; victron `docs/SOLAR_HA_DASHBOARD.md`). Dump plugs are HA helpers /
Energy device **Sim dump**; the brain does **not** scrape Lovelace. Dump-load,
watt ledger, and Ask ALFa context keep **signed floats**
(`jumper_w`, Battery 2 `stored_w`, shunt A, `surplus_w`).

Guest chat and consumer bots **never** receive the HA token or dump-load tools
([chat-data-isolation](../.cursor/rules/chat-data-isolation.mdc)).

---

## Dump vs 7B / 27B (independent)

Dump / diversion **actuation lives in Home Assistant** (victron package
`sim_dump_control.yaml`: Victron float hold, 1-minute re-bulk, solar-gone off,
[`switch.turn_on`](https://www.home-assistant.io/integrations/switch/) /
[`switch.turn_off`](https://www.home-assistant.io/integrations/switch/)).
See victron [DUMP_LOAD_HA_CONTROL.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/DUMP_LOAD_HA_CONTROL.md).

alfa-ai **does not** call those switch services from the dump ticker or `ha_dump_tick`.
The ticker **observes** HA states, records path-loss ledger + `ai_actions`, and
feeds Ask ALFa. Do **not** run a second dump on/off loop here.

| Path | What it does | Needs 7B / 27B? |
|------|----------------|-----------------|
| HA dump automations | Victron float hold, staged plugs, solar-gone / re-bulk off | **No.** HA only. |
| Dump ticker + `ha_dump_tick` | Observe + audit + watt-ledger briefing | **No.** |
| `ha_switch_on` / `ha_switch_off` | Optional remote one-entity toggle (not the dump algorithm) | **No.** |
| `ha_set_number` / `ha_select_option` | Immediate write of dump helpers (float/re-bulk V, min solar W, AC caps, max discharge, inverter dropdown) via official HA REST. Plug watts are live HA power sensors. | **No.** |
| Ask ALFa briefing / dual-check | Optional L1 explanation of last tick | Optional. Prefer **27B (`frontier-code`)** if you want a briefing. |
| Path B `draft-judge:` | Optional 7B draft + 27B judge **workspace write** | Optional. Gated **on** sim-dump allowlist; dump does **not** wait for Path B. |

Do **not** pick 7B vs 27B to keep dump working. Model size is Ask ALFa / Path B only
([ALFA_7B_27B_WORK_JUDGE.md](operations/ALFA_7B_27B_WORK_JUDGE.md)).

**Standing night loads (never dump-actuate):** LED strip, house/trailer fan, Pi4
(Victron BLE radio on Sungold A/C out), Trailer A/C. Leave them off `ha_switch_allowlist`
and optionally list them in `ha_never_auto`. Dump switches `switch.sim_ac_plug_*` are
the dump-load rail, not those standing circuits.

---

## Rename migration (dump load names, Sep 2026)

Operator-facing copy is **dump load** / **diversion load** only (Morningstar).
Legacy `ai_settings` keys and HA unique_ids from an earlier draft still exist in
some databases; the brain maps them to dump-load names. Public Lovelace copy stays
generic (**dump load**).

Canonical names in repo code, `ai_settings`, catalog, and audit:

| Old | New |
|-----|-----|
| `ha_solar_soak_enabled` | `ha_solar_dump_enabled` |
| `ha_solar_soak_auto_actuate` | `ha_solar_dump_auto_actuate` |
| `ha_soak_tick` (catalog) | `ha_dump_tick` (`ha_soak_tick` alias accepted) |
| `sensor.sim_soak_load_power` | `sensor.sim_dump_load_power` |
| `solar_soak_*` audit types | `solar_dump_*` (legacy rows keep old type strings) |
| `src/ops/solar_soak.py` | removed; canonical is `src/ops/solar_dump.py` |
| victron `install_sim_soak_plugs_ha.sh` | `install_sim_dump_plugs_ha.sh` |
| victron `SIM_SOAK_PLUGS.md` | `SIM_DUMP_PLUGS.md` |

**Brain code:** reads legacy `ha_solar_soak_*` settings and `sensor.sim_soak_load_power`
until the operator migrates DB + HA. **HA entity rename:** official docs do not
prescribe an in-place `entity_id` migration API -- on `apps`, reinstall the victron
sim package after `git pull` (creates `sensor.sim_dump_load_power`), update
`ha_load_entity` in Admin -> AI Actions -> Settings, and remove the old template
entity from HA if it remains. **Catalog:** Ask ALFa may still propose `ha_soak_tick`;
the brain resolves it to `ha_dump_tick`.

---

## Topology

```
alfa-ai-api (hub)
  Authorization: Bearer <long-lived token>
  GET  /api/states/<entity_id>
  POST /api/services/<domain>/<service>
        |
        v
Home Assistant Container (apps:8123)
        ^
        | MQTT discovery/state
Mosquitto apps:1883  <-- Pi4 Victron BLE, optional Sungold, Pi5 Theengs
Refoss EM16 LAN UDP 9989 --> HA (AC clamp, e.g. A3)
```

`POST /api/states/<entity_id>` only updates HA's **state machine** and **does not**
talk to the device. Control is always a **service call**.

---

## Site physics (loads must match the bus)

See victron [SOLAR_POWER_BALANCE.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SOLAR_POWER_BALANCE.md).

| Circuit | What dump loads do |
|---------|-------------------|
| **KU Renogy AC** (cargo trailer; cluster hosts) | Extra load uses **solar + KU LiTime**, not a utility meter. Put dump-load plugs **here** to use MPPT surplus at the plant. **10-11 Sep** EM16 A3 metered this leg. **15 Sep** A3/B2 meter Sungold AC-in instead -- do not use live A3 watts as dump load or cluster load until that clamp is back on the trailer. |
| **House AC** (Pi5 BLE plugs, typical utility) | Changes **house grid** draw. Separate allowlist / intent from trailer dump loads. |
| **KU paired MPPT** (`sensor.solar_controller_*`) | Instant Readout on the **BlueSolar 75/15** on the KU bus. **Not** T2 PV. |
| **T2 SmartSolar 100/50** (`sensor.smartsolar_100_50_*`) | Instant Readout on the T2 2s3p array. Dump sockets whose Inverter is T2 use this charger's **absorption/float** stage gate and T2 PV watts; headroom from `sensor.battery_1_power`. |
| **Sungold cart AC-in** (15 Sep A3/B2) | Cart conversion loss (~12% at 1190 W AC-in). Not the dump-load target. |

Default dump-load sensors target **MPPT solar**, **Battery 1** shunt V/A, and the **sim-plug aggregate**
(`sensor.sim_dump_load_power`) -- **not** EM16 A3. **16 Sep topology:** A3 meters Sungold
AC-in on the KU Renogy trailer outlet, **not** KU trailer house load. Do **not** use
`sensor.em16_a3_power` as dump load while A3 is Sungold AC-in (surplus would treat cart charging
as load). When a real KU house clamp exists, set `ha_load_entity` in Admin AI Settings; confirm
ids with `GET /api/states` ([REST API](https://developers.home-assistant.io/docs/api/rest/)).

Victron charge stage strings (MQTT Instant Readout, lowercase): `bulk`,
`absorption`, `float`, … ([BlueSolar monitoring](https://www.victronenergy.com/media/pg/Manual_BlueSolar_MPPT_75-10_up_to_100-20/en/monitoring.html)).
**Float** = maintain fully charged. Dump sockets may be added while that bus charger is in **absorption or float** (not bulk), once start volts, solar, SoC, and SmartShunt net charge headroom pass (plug estimate + min solar W). Sungold-inverter loads use the T2 shunt. HA does not write the MPPT. Shed at re-bulk, when PV drops below min solar, or when shunt charge falls below reserve. Surplus watts are **audit only**.

Use **power (W)** sensors for live surplus, not Energy dashboard kWh
([Energy FAQ](https://www.home-assistant.io/docs/energy/faq/)).

---

## Kill switches (layered)

| Layer | Default | Role |
|-------|---------|------|
| `ALFA_AI_HOME_ASSISTANT_ENABLED=0` | **off** | Brain env. No REST, no ticker, no `ha_*` catalog. Redeploy API after flip. |
| Token file missing | -- | Same as off. |
| `ha_solar_dump_enabled` | `true` | Settings. Ticker sleeps until this is false (no HA poll while false). |
| `ha_solar_dump_auto_actuate` | `false` | Unused for dump on/off (HA automations own switches). Legacy Settings key only. |
| `ha_switch_allowlist` | six `switch.sim_ac_plug_*` (see below) | Ask ALFa `ha_switch_on` / `ha_switch_off` one-shots and Path B sim-only guard. Empty = those catalog actions never toggle. |
| `ha_switch_watts` | optional overlay | `entity_id=watts` only when `ha_load_entity` is a plant clamp. Dump plugs use live HA power sensors. |

**Operator (2026-09-18):** dump **on/off is Home Assistant** (`sim_dump_control.yaml`).
Ask ALFa `ha_dump_tick` observes only. `ha_switch_on` / `ha_switch_off` remain
optional remote one-shots when HA env + token and allowlist match (not the dump
algorithm). `ha_set_number` / `ha_select_option` write **sim dump** helpers
(float/re-bulk V, min solar W, AC caps, inverter dropdown)
**immediately** when HA env + token are on
(same REST as a Cursor session; no Approve). Solar dump is outside NIST
(operator 2026-09-19).
They are not how HA learns a random appliance was plugged into T2, KU, or Sungold:
those loads show on `sensor.battery_1_power` / `sensor.battery_2_power`
(Victron SmartShunt [operation 5.2](https://www.victronenergy.com/media/pg/SmartShunt/en/operation.html)
+charge / -discharge) and on `sensor.sungold_sph302480a_load_power` plus cart
battery V×A (Sungold has no Victron shunt). Logged to `ai_actions`.
Other catalog actions (incl. `run_command`) unchanged.

### Simulated dump-load plugs (HA YAML, not MQTT)

The six sim loads are **not** MQTT devices or a Pi sidecar. They are an **opt-in HA
package** in the victron sibling repo: `input_boolean` internal state plus
[template switches](https://www.home-assistant.io/integrations/template/) and template
power sensors ([input boolean](https://www.home-assistant.io/integrations/input_boolean/),
[packages](https://www.home-assistant.io/docs/configuration/packages/)). Dump **on/off**
is the victron `sim_dump_control.yaml` package. alfa-ai does not POST switch services
from the dump ticker. Do **not** use
`POST /api/states` for load control.

**Allowlist `switch.sim_ac_plug_*` only.** Do **not** allowlist
`input_boolean.sim_ac_plug_N_internal` (internal helpers for template state).

**Path B energy rail (operator 2026-09-15):** optional 7B draft + 27B judge may
auto-write **confirmed** project drafts under `ALFA_AI_WORKSPACE_ROOT` **only while**
`ha_switch_allowlist` is a subset of these sim plugs and HA is ready. That guardrail
protects Path B file writes. It is **not** a dump controller: dump ticks with or
without Path B, 7B, or 27B. Adding a **real** house entity to the dump allowlist
**pauses** Path B auto-write (JSONL and chat drafts still run). See
[ALFA_7B_27B_WORK_JUDGE.md](operations/ALFA_7B_27B_WORK_JUDGE.md) and
`path_b_sim_dump_guardrail()`.

| entity_id (allowlist) | Role |
|-----------------------|------|
| `switch.sim_ac_plug_1` ... `_6` | Dump switch (template until Govee MQTT switch is renamed to this id) |

Do **not** allowlist standing night loads (LED strip, house/trailer fan, Pi4, Trailer A/C).

Power sensors:

| entity_id | When ON | When OFF |
|-----------|---------|----------|
| `sensor.sim_ac_plug_N_power` | live watts from `input_text.dump_plug_N_power_entity` | `0` |
| `sensor.sim_dump_load_power` | sum of numeric plug power sensors | `0` when all off or unknown |

HA dump staging confirms **site load delta** after `input_number.dump_site_confirm_s`
(default 5 s) (victron
[DUMP_LOAD_HA_CONTROL.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/DUMP_LOAD_HA_CONTROL.md)).
Dump hardware is Govee H5082; HA Core has no plug integration. A MQTT sidecar
(same shape as Victron BLE) is not in the victron repo yet.
HA texts when Sungold AC-out stays above site solar for 10 min (`notify`,
Companion `mobile_app_*` via `dump_notify_service`). The brain does **not**
send that alert or shed dump plugs.

Default surplus math reads `ha_load_entity` (`sensor.sim_dump_load_power`).

**Enable on `apps` only** (package is not on `/opt/homeassistant` until installed):

```bash
cd /home/operator/victron-ble2mqtt-integration
git pull --ff-only origin main
bash scripts/install_sim_dump_plugs_ha.sh
```

Canonical operator doc: victron
[docs/SIM_DUMP_PLUGS.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SIM_DUMP_PLUGS.md).
Local clone: `../victron-ble2mqtt-integration/docs/SIM_DUMP_PLUGS.md`. Source package:
`config/packages/sim_dump_plugs.yaml`; installer: `scripts/install_sim_dump_plugs_ha.sh`.

Example REST control from the brain (`hub`):

```http
POST /api/services/switch/turn_on
Content-Type: application/json
Authorization: Bearer <long-lived token>

{"entity_id": "switch.sim_ac_plug_1"}
```

`ALFA_AI_HOME_ASSISTANT_ENABLED=0` or a missing token file is a **hard kill**: no REST,
no ticker, and no `ha_*` catalog actions even when sim entities exist in HA.

Defaults seed all six `switch.sim_ac_plug_*` on the allowlist. Plug watts come from
HA live power sensors (`sensor.sim_dump_load_power`), not `ha_switch_watts`.

---

## Operator settings (`ai_settings`)

**Seed vs live DB:** on API startup, `AiSettingStore._seed_defaults()` runs
`INSERT ... ON CONFLICT (key) DO UPDATE SET description = EXCLUDED.description,
editable_by_ai = EXCLUDED.editable_by_ai` -- it **never** overwrites `value`. A database
that was seeded earlier with `ha_load_entity=sensor.em16_a3_power` keeps that value until
the operator writes `ha_load_entity=sensor.sim_dump_load_power` in **Admin -> AI Actions ->
Settings** (`ha_load_entity` is not a policy key; Ask ALFa cannot Approve-write it).
Fresh installs get code defaults from the INSERT path only.

Edit in **Admin -> AI Actions -> Settings**. Policy keys (`ha_solar_dump_enabled`,
`ha_solar_dump_auto_actuate`, `ha_switch_allowlist`) need **Approve** when Ask ALFa
proposes them; the Settings tab can set them as the operator.

| Key | Default | Meaning |
|-----|---------|---------|
| `ha_solar_dump_enabled` | `true` | Arm the dump-load ticker logic |
| `ha_solar_dump_auto_actuate` | `false` | Unused for dump switches (HA owns on/off) |
| `ha_switch_allowlist` | six `switch.sim_ac_plug_*` | Catalog one-shots + Path B sim-only guard |
| `ha_switch_watts` | empty | Optional overlay when `ha_load_entity` is a plant clamp. Not dump-plug ratings. |
| `ha_never_auto` | `` | Extra never-toggle list (subtracted from allowlist) |
| `ha_solar_entity` | `sensor.solar_controller_solar` | Instantaneous PV W from the **paired KU BlueSolar 75/15** (`sensor.solar_controller_*`). Do **not** treat this as T2 SmartSolar 100/50 PV (T2 charger not in HA until its Instant Readout key is paired). HA assigns `entity_id` from MQTT discovery `name` / `unique_id` / `default_entity_id` ([MQTT integration](https://www.home-assistant.io/integrations/mqtt/)). |
| `ha_load_entity` | `sensor.sim_dump_load_power` | Plant AC load W for surplus math. Default is the sim-plug aggregate (`0` when all OFF). **Do not** point dump load at `sensor.em16_a3_power`: A3 is the cargo-trailer hot leg (Sungold A/C INPUT **plus** trailer vent fan), not a dump-load clamp and not plant house load. Sungold A/C out feeds **Pi4** plus anything else on that outlet; `sensor.sungold_sph302480a_load_power` is the **total** (LCD INV OUTPUT LOAD KW), not Pi4-only. When a real KU house clamp exists, set `ha_load_entity` to that sensor; see victron [SOLAR_POWER_BALANCE.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SOLAR_POWER_BALANCE.md). |
| `ha_soc_entity` | `sensor.battery_1_state_of_charge` | Battery 1 SoC % (Victron MQTT). **Display only** while `ha_soc_unsynced=true`. |
| `ha_shunt_voltage_entity` | `sensor.battery_1_voltage` | T2 / Battery 1 HQ2239CQYT2 volts (thinking + dump metrics). LiTime absorb 28.4-29.2 V is nameplate, not a Victron % map. Alias `sensor.battery_1_battery_voltage` is tried at runtime if present. |
| `ha_shunt_current_entity` | `sensor.battery_1_current` | T2 / Battery 1 amps. SmartShunt +charge / -discharge. Alias `sensor.battery_1_battery_current` is tried at runtime if present. KU HQ2239JTRKU `sensor.battery_2_voltage` / `sensor.battery_2_current` (and `_battery_*` aliases) are ledger/metrics only -- not dump skip gates. |
| `ha_soc_unsynced` | `true` | Skip `ha_min_soc_percent`. SmartShunt SoC is unsynchronised until VictronConnect resets it at full ([operation 5.7](https://www.victronenergy.com/media/pg/SmartShunt/en/operation.html)). Official docs are silent on a voltage-to-% map; float voltage is the full-enough gate while unsynced. |
| `ha_charge_state_entity` | `sensor.solar_controller_charge_state` | MPPT stage (`float` / `absorption` / …) from Victron MQTT discovery. |
| `ha_charge_states_ok` | `absorption,float` | Allowed MPPT stages for dump-on briefing (Victron battery-first; not bulk). |
| `ha_weather_entity` | `weather.417373300314` | Outdoor weather for observe-only context (Ecobee; same entity as Overview / Solar plant forecast card). Empty skips weather in dump ticker and Ask ALFa energy context. Dump does **not** toggle loads from forecast or temperature. |
| `ha_min_soc_percent` | `95` | SoC floor when `ha_soc_unsynced=false`. Target leftover after solar stops. |
| `ha_min_solar_watts` | `50` | PV below this is solar-gone. HA `input_number.dump_min_solar_w` overrides when present. |
| `ha_min_surplus_watts` | `200` | Audit-only leftover PV band. **Not** the dump ON trigger. |
| `ha_off_surplus_watts` | `50` | Audit-only leftover PV band. Dump OFF is solar-gone / re-bulk / left-float. |
| `ha_interval_seconds` | `900` | Ticker period (60-3600) |
| `ha_max_concurrent_on` | `6` | Max allowlisted switches left on by dump loads (default fits all sim plugs) |
| `ha_min_on_seconds` | `600` | Min dwell after turn_on |
| `ha_min_off_seconds` | `300` | Min dwell after turn_off |

**Effective load (surplus math):**

```
surplus_w = solar_W - effective_load_w
combined_losses_w = sum of metered conversion hops (paired KU 75/15, Sungold)
combined_vdrop_loss_w = sum of metered |ΔV × I| conductor losses (D/C and A/C kept separate for ΔV totals)
combined_path_losses_w = combined_losses_w + combined_vdrop_loss_w
surplus_after_path_losses_w = surplus_w - combined_path_losses_w
```

Brain **audit** surplus uses **`surplus_after_path_losses_w`**. Switch on/off is Home
Assistant Threshold automations (victron `sim_dump_control.yaml`). Conversion and
voltage-drop watts are two numbers plus this total. **Do not mix 24 V D/C with 120 V A/C**
into one ΔV
([Victron Wiring Unlimited §2.7](https://www.victronenergy.com/media/pg/The_Wiring_Unlimited_book/en/theory.html):
V = I×R, cable loss P = I²R; with both-end voltages P ≈ |ΔV × I|). Never invent cable AWG.

Trailer outlet hop (operator 17 Sep 2026): `trailer_outlet_W` ≈ |A3| (or |B3| when that
breaker is the Sungold-outlet path). `sungold_ac_in_W` = Sungold A/C INPUT V×A
([reprint §4.1](https://www.solaris-shop.com/content/3000W_SPH302480A_20231128.pdf)).
`vent_fan_W` ≈ max(0, trailer_outlet_W − sungold_ac_in_W). **A3 is not Sungold-only.**
Pi4 sits on Sungold A/C OUTPUT (unmetered; not a sim dump plug).

Brain **audit** surplus uses **`surplus_after_path_losses_w`**, not raw `surplus_w`. Math starts at
panel watts (HA solar power, or V*A when power is missing). Each hop records watts in
and watts out. **Battery charge is storage, not loss** (SmartShunt
[+charge / -discharge](https://www.victronenergy.com/media/pg/SmartShunt/en/operation.html)).
**Conversion loss** is in minus out when both ends are metered (paired KU 75/15
charge+load out; Sungold `(A/C in + PV) - battery input - A/C out` per Sungold reprint
[§4.1](https://www.solaris-shop.com/content/3000W_SPH302480A_20231128.pdf)).
T2 SmartSolar 100/50 solar watts are `sensor.smartsolar_100_50_solar_power`. The paired KU 75/15 is `sensor.solar_controller_*`. The second KU 75/15 has no BLE dongle. Its watts are the shunt balance `Battery2 W - paired 75/15 charge W + jumper W` (display clamped to >= 0 W), where signed `jumper W = Battery1 W - SmartSolar battery W + measured T2 bus load W` (+ into T2 from KU). Measured T2 bus load is Sungold `charging_power` only. An ON T2 dump plug with no meter is left inside the shunt difference and is not given the 25 W dump minimum. A one-third of SmartSolar PV is only a size check, not the measurement.
`jumper_w` = Battery 1 W minus SmartSolar battery W plus T2 bus load W (+ into T2 from KU). Silent 75/15 W = max(0, Battery 2 W minus paired 75/15 charge W plus that jumper). Equal **1/2**
(`ku_charger_equal_share_w`) applies only when the shunt lower bound is complete.
Do not invent a site derate. Battery 2 **load** equals KU Renogy
A/C est (|A3|); that is not dump-load `effective_load_w`. Morningstar diversion
[§6.0](https://www.morningstarcorp.com/wp-content/uploads/technical-doc-diversion-manual-en.pdf)
diverts **excess source energy** after the battery is full -- path losses reduce how much
energy is actually available to dump.

Ask ALFa energy context (`home_energy_ops`) copies **signed** last-tick floats:
`last_surplus_w`, `last_jumper_w`, `last_batt2_stored_w`, `last_shunt_a` /
`last_t2_shunt_a` / `last_ku_shunt_a`, `last_combined_losses_w`, and
`last_surplus_after_path_losses_w`, plus last-tick **outdoor weather**
(`last_weather_condition`, `last_weather_temperature`, truncated daily forecast)
when `ha_weather_entity` is set. Inspect `ha_get_states` prints the HA `state`
string as-is (including a leading `-`). `ha_dump_tick` stdout is the same dump
`meta` JSON. None of those paths read CSS color.

**Outdoor weather (observe only):** default `ha_weather_entity` =
`weather.417373300314` (Ecobee weather; same Overview Living Room popup /
Solar plant [weather-forecast](https://www.home-assistant.io/dashboards/weather-forecast/)
card). Current condition is `GET /api/states/{entity_id}`. Forecast is
`POST /api/services/weather/get_forecasts?return_response` with
`{"entity_id": "...", "type": "daily"}`
([REST API](https://developers.home-assistant.io/docs/api/rest/),
[weather.get_forecasts](https://www.home-assistant.io/integrations/weather/)).
Dump **does not** turn plugs on or off from forecast or ambient temperature.
Ask ALFa inspect `ha_get_forecasts` / `ha_get_state` may read them for operator
decisions. `climate.417373300314` is indoor setpoint only.

- **Default (`ha_load_entity` = `sensor.sim_dump_load_power`):** `effective_load_w` is the
  HA template sum of ON sim plug watts (`0` when all OFF). No plant AC load is assumed until
  a real KU house EM16 channel is configured. `ha_switch_watts` is **not** added on top
  (the sensor already reflects ON sim plugs).
- **Real plant clamp configured:** when `ha_load_entity` is a house/trailer EM16 sensor
  (not `sensor.sim_dump_load_power`), `effective_load_w = load_sensor_W + sum(rated_W for
  each ON entity in ha_switch_watts)` (plant draw + virtual sim addend).
- **Solar sensor** must be numeric; otherwise the tick skips.
- **Load sensor unavailable:** if `ha_switch_watts` is non-empty, use **sim plug watts only**
  from the watts map (fallback before `sensor.sim_dump_load_power` exists in HA).
- **Double-count warning:** with a real plant clamp, if a physical plug on that clamp **and**
  a matching sim entity are both ON, both count -- acceptable for lab; remove sim ids from
  `ha_switch_watts` when going live.

Unavailable / non-numeric **solar** skips the tick (log + `solar_dump_observed` with `skipped`).

**SoC gate:** skipped while `ha_soc_unsynced=true` (default). Victron SmartShunt SoC
must be synchronised in VictronConnect when the battery is actually full
([operation 5.7](https://www.victronenergy.com/media/pg/SmartShunt/en/operation.html));
this repo does **not** reset SoC over MQTT or HA. Official docs are silent on a
numeric substitute for SoC -- do not invent one. Tick meta uses
`soc_gate=skipped_unsynced` and thinking/log
`SoC gate skipped: unsynced; using V/A + charge state only`. Charge state for
dump-on briefing expects **`absorption` or `float`** (not bulk). Dump metrics log **T2 shunt V/A** (HQ2239CQYT2) and
**KU shunt V/A** (HQ2239JTRKU) separately; T2 volts are compared to the Victron
float / re-bulk helpers (default **27.0 V / 26.8 V** on 24 V LiFePO4). Current is
signed +charge/-discharge. After a real VictronConnect sync, set `ha_soc_unsynced=false`
and HA `dump_soc_unsynced` off to restore `ha_min_soc_percent` **95**.

Confirm entity ids with Ask ALFa inspect `ha_get_states` (host `105`) after the token
works. Dump settings **default to live MQTT `entity_id`s** on `apps` (Victron MQTT
discovery, 16 Sep 2026). HA assigns those ids from discovery payload
([MQTT integration](https://www.home-assistant.io/integrations/mqtt/),
[MQTT Sensor](https://www.home-assistant.io/integrations/sensor.mqtt/)) -- not from
alfa-ai setting key names. Early seeds used invented ids (`sensor.solar_controller_solar_power`,
`sensor.solar_controller_battery_state`, `sensor.battery_1_soc`) that **never existed**
in HA. The brain remaps those stale DB values to live ids at load time (runtime only;
seed `INSERT` does not overwrite an existing `value`).

| Stale DB / invented id (remapped at load) | Live MQTT `entity_id` (code default) |
|-------------------------------------------|--------------------------------------|
| `sensor.solar_controller_solar_power` | `sensor.solar_controller_solar` |
| `sensor.solar_controller_battery_state` | `sensor.solar_controller_charge_state` |
| `sensor.battery_1_soc` | `sensor.battery_1_state_of_charge` |
| `sensor.battery_2_soc` | `sensor.battery_2_state_of_charge` |

Shunt V/A (`ha_shunt_voltage_entity` / `ha_shunt_current_entity`, defaults
`sensor.battery_1_voltage` / `sensor.battery_1_current`) feed the watt-ledger **and**
the Victron float / re-bulk dump-on gate (T2 defaults 27.0 V / 26.8 V). Runtime
`_state_row` also tries
`sensor.battery_1_battery_voltage` / `sensor.battery_1_battery_current` if those
MQTT ids exist. Battery 2 V/A and those aliases are the same class. If none of
those ids appear in `GET /api/states`, omit them from `meta.missing_entity_ids`.
Do **not** create HA template sensors to invent missing ids. HA already has
`binary_sensor.dump_v_float_*` / `dump_v_rebulk_*` in `sim_dump_control.yaml`.

`meta.missing_entity_ids` lists **required** dump ids with no row in
`GET /api/states` after remap and alias fallback: solar, load, charge state, each
allowlisted switch; SoC only when `ha_soc_unsynced=false`. An id is missing only when
neither the setting id nor a known alias resolves in the fetched map
([REST API `GET /api/states`](https://developers.home-assistant.io/docs/api/rest/)
returns only entities that exist; absent ids are omitted from the collection, not a
404 for the whole collection). Optional shunt / Battery 2 V/A are fetched for ledger
metrics but never yellow-listed as missing.

**Fetch must not abort the tick** when an optional sensor is absent. Dump calls
`ha_get_states(..., require_all=False)` so required-but-missing rows appear in
`meta.missing_entity_ids` and `thinking`, then `decide_dump()` runs on whatever rows
exist. Whole-tick skip (HTTP 401/5xx, token missing) still records
`solar_dump_observed` with `ok=false`. Inspect `ha_get_state` of a single missing id
still 404s. Do **not** invent a 2x T2 watts reading for silent KU Victron chargers.

---

## Token (operator, one-time)

1. In HA UI on `apps`: create a dedicated user (e.g. `alfa_ai`), not the owner if possible.
2. That user's **Profile -> Security -> Long-lived access tokens -> Create Token**.
   Copy once; HA does not store the string ([Auth API](https://developers.home-assistant.io/docs/auth_api/#long-lived-access-token)).
3. Keep the token **only** as gitignored
   `deploy/secrets/home-assistant/long-lived.token` (one line, no quotes, mode `600`
   on Linux). Same relative path in every alfa-ai clone that must call HA.
   **Do not** put the token string in `deploy/.env`, `host105-ai.env`, chat, or git.
   Point env at the file:

| Host | File | Used by |
|------|------|---------|
| **`orchestrator` (`operator`)** | `C:/Users/operator\alfa-ai\deploy\secrets\home-assistant\long-lived.token` | Optional local HA REST. **Present** (operator 2026-09-16). |
| **`hub` (`operator`)** | `/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/secrets/home-assistant/long-lived.token` | Brain API bind-mount `ALFA_AI_HOME_ASSISTANT_SECRETS_DIR`. Operator-owned; agents do not SSH `hub`. |
| **`apps` (`ansible`)** | `/home/operator/alfa-ai/deploy/secrets/home-assistant/long-lived.token` | Copy from `orchestrator` when this clone must call HA. HA Container does **not** read this file. Not in `host105-ai.env`. |

`orchestrator` is **`operator`**, not `ansible`. Do not `ssh operator@orchestrator` for this file.
HA does not keep the plaintext after Create Token
([Auth API](https://developers.home-assistant.io/docs/auth_api/#long-lived-access-token)).
4. On **`hub` only**, set in operator `deploy/.env` (see [env.example](../deploy/env.example)):

```bash
ALFA_AI_HOME_ASSISTANT_ENABLED=1
ALFA_AI_HOME_ASSISTANT_BASE_URL=http://apps
ALFA_AI_HOME_ASSISTANT_TOKEN_FILE=/app/secrets/home-assistant/long-lived.token
ALFA_AI_HOME_ASSISTANT_SECRETS_DIR=./secrets/home-assistant
```

5. Redeploy **`alfa-ai-api` only** (`scripts/brain_redeploy_api.sh`). Do **not** run
   cluster start/stop for this.

Keep `:8123` LAN-only ([HOMEASSISTANT_105_OPERATOR.md](HOMEASSISTANT_105_OPERATOR.md)).
Never paste the token into chat, git, or `run_command` curl (Approve cards log the
command).

---

## Ask ALFa catalog (`home_energy` pack)

Internal to `alfa-ai-api` (httpx). **Not SSH.** Host key is always **`105`**
(HA lives there). Does **not** need `ALFA_AI_HOST_ACTIONS_ENABLED` or the SSH key.

| Key | Tier | Gate |
|-----|------|------|
| `ha_get_states` | 1 read | Inspect auto-run when `ask_alfa_inspect_autorun` and HA env on |
| `ha_get_state` | 1 read | Same; `params.entity_id` |
| `ha_get_forecasts` | 1 read | Same; `params.entity_id` (must be `weather.*`, default `weather.417373300314`); `params.type` one of `daily` / `hourly` / `twice_daily` (default `daily`). Official `weather.get_forecasts` with `?return_response`. |
| `ha_switch_on` | 2 mutate | **Auto-actuate** when HA env + token on; entity must be in `ha_switch_allowlist` |
| `ha_switch_off` | 2 mutate | Same |
| `ha_dump_tick` | 1 read | Immediate **observe** tick (same as ticker; no switch services). **No LLM / 7B / 27B.** |
| `ha_set_number` | 2 mutate | **Auto-actuate** when HA env + token on. `input_number.set_value` on dump helpers only. |
| `ha_select_option` | 2 mutate | **Auto-actuate** when HA env + token on. Plug inverter `T2`/`KU`/`Sungold` only. |

Deterministic regex `Propose ha_switch_on on host 105` without `params.entity_id` is a
validation error (no HA REST call); use the monitoring-agent `propose_host_action` tool with
`params.entity_id` to name a plug.

Pack **`home_energy`** is **default off** in AI Config. Soft-disable does **not**
block HA solar dump auto-actuate (`ha_switch_*`, `ha_set_number`,
`ha_select_option`) -- same as today for switch one-shots.

---

## Audit

| Event | `ai_actions.action_type` |
|-------|--------------------------|
| Ticker snapshot | `solar_dump_observed` |
| Would toggle (comparison vs HA; brain does not POST) | `solar_dump_recommended` |
| Legacy ticker service call | `solar_dump_actuated` (historical only) |
| Ask ALFa auto `ha_switch_*` | `host_command_executed` |
| Ask ALFa `ha_dump_tick` | `host_command_executed` plus `solar_dump_observed` / `_recommended` |
| Inspect `ha_get_states` / `ha_get_state` / `ha_get_forecasts` / `ha_dump_tick` | `host_inspect_executed` |

**Operator UI (Admin -> AI Actions -> Dump load):** live last-tick panel plus the
dump rows in the feed. `GET /alfa-ai/api/admin/dump-status` (admin JWT) returns the
in-memory last tick (`get_last_dump_summary`), `ha_interval_seconds`, HA ready
flags, and `recorded_at`. The browser polls that endpoint and
`GET /alfa-ai/api/admin/ai-actions?category=dump` about every **10s**. That is UI
refresh only -- the ticker period stays `ha_interval_seconds` (default 900). Do
not log the Bearer token. Service summaries may include entity_id and on/off.

Each `solar_dump_observed` `detail` includes:

| Field | Meaning |
|-------|---------|
| `ok` | HA collection GET succeeded |
| `meta` | Watts, surplus, path losses, charge_state, soc_gate, weather (observe-only) |
| `meta.thinking` | Ordered human-readable decision lines (program, not LLM) |
| `meta.missing_entity_ids` | Required dump ids absent from `GET /api/states` after remap/alias fallback (not optional shunt/Battery 2 V/A) |
| `decisions` | Per allowlisted switch: `entity_id`, `action` (`on`/`off`/`skip`), `reason` |

**Circuit breaker:** five consecutive HA HTTP failures are logged on observe ticks.
Dump switch on/off stays in Home Assistant regardless.

---

## Guest / public

No HA tools on `/alfa-ai/api/guest/chat`. Public error strings must not include
`apps`, `:8123`, or token paths ([public-surface-security](../.cursor/rules/public-surface-security.mdc)).

---

## Related

- [AI_AUTONOMY_AND_OVERSIGHT.md](AI_AUTONOMY_AND_OVERSIGHT.md)
- [AI_ACTIONS.md](AI_ACTIONS.md)
- [ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md)
- [HOMEASSISTANT_105_OPERATOR.md](HOMEASSISTANT_105_OPERATOR.md)
- [RELATED_VICTRON_HOMEAUTO.md](RELATED_VICTRON_HOMEAUTO.md)
- victron `docs/ALFA_AI_HOW_TO_USE.md` (control is brain-side; edge collectors stay read-only MQTT)
