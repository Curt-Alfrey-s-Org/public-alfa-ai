# Related repo — Victron / Home Assistant edge (Raspberry Pi)

The **[victron-ble2mqtt-integration](https://github.com/example/victron-ble2mqtt-integration)** repository runs on the **Pis** (BLE/USB collectors) and supplies the Home Assistant Container compose used on **`apps`**. **Mosquitto and HA live on `apps`** so the dashboard stays up when Pi4 is down. Pi4/Pi5 publish MQTT to `apps`. It is **not** part of the GPU cluster. Operator: [HOMEASSISTANT_105_OPERATOR.md](HOMEASSISTANT_105_OPERATOR.md) (Solar/Refoss A/V/W display tenths; Battery 1 Instant Readout key must be exactly 32 hex; HA labels `sungold` / `victron` / `refoss`; Victron Solar tiles need live MQTT **state** from Pi4 BLE, not only discovery).

## Why this file exists in alfa-ai

- **Cursor / agents:** On the dev server, open **alfa-ai**, **victron-ble2mqtt-integration**, and **monitoring** in one **multi-root workspace** so search and edits span repos (typical paths under `/home/operator/`).
- **hub hub policy:** Large-artifact rules and hub paths are documented here in **`docs/HUB_ARTIFACTS.md`** and **`docs/CLUSTER_SHARED_STORAGE.md`**. The Victron stack only needs hub workflows when you **airgap** or **mirror** Docker base images (see Victron doc below).
- **Monitoring:** Prometheus on **apps** scrapes the Pi after **`monitoring/hosts/pi4-victron/`** setup — see that folder’s `README.md`.
- **Agent SSH:** Cursor on **`orchestrator`** uses dedicated key **`id_ed25519_93_223`** → **`operator@orchestrator`** (hostname `pi4`) and the same key → **`operator@orchestrator`** (Pi5). See **`docs/PI4_VICTRON_OPERATOR.md`** and **`docs/PI5_OPERATOR.md`**.
- **Power balance:** victron [docs/SOLAR_POWER_BALANCE.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SOLAR_POWER_BALANCE.md) -- T2 vs KU buses, two Renogy 2 kW, two BlueSolar 75/15 MPPT on KU (PWM removed 2026-10-02). Do not add A3+B2. **10-11 Sep** A3 = trailer; **15 Sep** A3 = Sungold AC-in (cart loss ~12%). Sungold is the emergency cart. Local clone: `victron-ble2mqtt-integration/docs/SOLAR_POWER_BALANCE.md`.
- **Brain load control:** alfa-ai may read HA REST for audit and Ask ALFa. Dump **on/off** is Home Assistant (`sim_dump_control.yaml`; install `install_sim_dump_control_ha.sh`). [HOME_ASSISTANT_BRAIN_INTEGRATION.md](HOME_ASSISTANT_BRAIN_INTEGRATION.md).
- **Simulated dump-load plugs (lab):** six **template** `switch.sim_ac_plug_*` entities (HA YAML package on `apps`, **not** MQTT). Install: `bash scripts/install_sim_dump_plugs_ha.sh` from the victron clone after `git pull`. Entity contract and watts table: victron [docs/SIM_DUMP_PLUGS.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/SIM_DUMP_PLUGS.md).

## Canonical cross-repo doc

**[victron-ble2mqtt-integration / docs / ALFA_CLUSTER_INTEGRATION.md](https://github.com/example/victron-ble2mqtt-integration/blob/main/docs/ALFA_CLUSTER_INTEGRATION.md)** — hub usage, monitoring steps, and explicit **not Petals** scope.
