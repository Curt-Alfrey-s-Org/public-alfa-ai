"""Deterministic solar dump-load observe via Home Assistant (no LLM).

HA automations own switch on/off using Victron float hold and re-bulk voltage
(BlueSolar operation: Vbat < Vfloat-offset for 1 minute). This module observes
those HA states, keeps the watt-ledger, and recommends at most one staged ON.
Surplus watts are briefing only (float throttles PV to the load).
Does not require 7B, 27B, LiteLLM, or Path B -- model size is Ask ALFa dual-check
only. See docs/HOME_ASSISTANT_BRAIN_INTEGRATION.md.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from datetime import UTC, datetime
from typing import Any, Literal

from src.api.models.ai_action import (
    ACTION_SOLAR_DUMP_OBSERVED,
    ACTION_SOLAR_DUMP_RECOMMENDED,
)
from src.ops.home_assistant_client import (
    DEFAULT_WEATHER_ENTITY,
    HomeAssistantError,
    compact_forecast_entries,
    forecast_entries_from_response,
    ha_get_forecasts,
    ha_get_state,
    ha_get_states,
    home_assistant_enabled,
    home_assistant_ready,
    validate_entity_id,
    validate_weather_entity_id,
)
from src.ops.solar_watt_ledger import apply_ledger_to_meta

logger = logging.getLogger(__name__)

DumpDecision = tuple[str, Literal["on", "off", "skip"], str]

_SIM_PLUG_ALLOWLIST = (
    "switch.sim_ac_plug_1,switch.sim_ac_plug_2,switch.sim_ac_plug_3,"
    "switch.sim_ac_plug_4,switch.sim_ac_plug_5,switch.sim_ac_plug_6"
)
_SIM_PLUG_WATTS = ""

# Victron sim_dump_control.yaml helpers Ask ALFa may set immediately (HA REST; not dump on/off).
DUMP_HA_NUMBER_HELPERS = frozenset(
    {
        "input_number.dump_ac_limit_t2_w",
        "input_number.dump_ac_limit_ku_w",
        "input_number.dump_ac_limit_sph_w",
        "input_number.dump_max_discharge_t2_w",
        "input_number.dump_max_discharge_ku_w",
        "input_number.dump_max_discharge_sph_w",
        "input_number.dump_float_t2_v",
        "input_number.dump_float_ku_v",
        "input_number.dump_float_sph_v",
        "input_number.dump_rebulk_t2_v",
        "input_number.dump_rebulk_ku_v",
        "input_number.dump_rebulk_sph_v",
        "input_number.dump_min_solar_w",
        "input_number.dump_min_soc_percent",
    }
)
DUMP_HA_SELECT_HELPERS = frozenset(
    {
        "input_select.dump_plug_1_inverter",
        "input_select.dump_plug_2_inverter",
        "input_select.dump_plug_3_inverter",
        "input_select.dump_plug_4_inverter",
        "input_select.dump_plug_5_inverter",
        "input_select.dump_plug_6_inverter",
    }
)
DUMP_HA_SELECT_OPTIONS = frozenset({"T2", "KU", "Sungold"})
_DEFAULT_FLOAT_V = 27.0
_DEFAULT_REBULK_V = 26.8
_HA_DUMP_FLOAT_HELPER = "input_number.dump_float_t2_v"
_HA_DUMP_REBULK_HELPER = "input_number.dump_rebulk_t2_v"
_HA_DUMP_MIN_SOLAR_HELPER = "input_number.dump_min_solar_w"
_HA_DUMP_CHARGE_FLOAT = "binary_sensor.dump_charge_float"
_HA_DUMP_SOLAR_PRESENT = "binary_sensor.dump_solar_present"
_HA_DUMP_V_REBULK_T2 = "binary_sensor.dump_v_rebulk_t2"
_HA_DUMP_V_FLOAT_T2 = "binary_sensor.dump_v_float_t2"
_HA_DUMP_SOC_OK = "binary_sensor.dump_soc_ok"
# HA template aggregate; 0 plant AC load until a real KU house EM16 channel is configured.
_SIM_DUMP_LOAD_ENTITY = "sensor.sim_dump_load_power"
_LEGACY_SIM_DUMP_LOAD_ENTITY = "sensor.sim_soak_load_power"

_LEGACY_SETTING_KEYS: dict[str, str] = {
    "ha_solar_soak_enabled": "ha_solar_dump_enabled",
    "ha_solar_soak_auto_actuate": "ha_solar_dump_auto_actuate",
}

_last_toggle: dict[str, tuple[str, float]] = {}
_last_dump_summary: dict[str, Any] | None = None
_consecutive_http_failures = 0

_DEFAULTS: dict[str, str] = {
    "ha_solar_dump_enabled": "true",
    "ha_solar_dump_auto_actuate": "false",
    "ha_switch_allowlist": _SIM_PLUG_ALLOWLIST,
    "ha_switch_watts": _SIM_PLUG_WATTS,
    "ha_never_auto": "",
    "ha_solar_entity": "sensor.solar_controller_solar",
    "ha_load_entity": _SIM_DUMP_LOAD_ENTITY,
    "ha_soc_entity": "sensor.battery_1_state_of_charge",
    "ha_shunt_voltage_entity": "sensor.battery_1_voltage",
    "ha_shunt_current_entity": "sensor.battery_1_current",
    "ha_soc_unsynced": "true",
    "ha_charge_state_entity": "sensor.solar_controller_charge_state",
    "ha_charge_states_ok": "absorption,float",
    "ha_weather_entity": DEFAULT_WEATHER_ENTITY,
    "ha_min_soc_percent": "95",
    "ha_min_solar_watts": "50",
    "ha_min_surplus_watts": "200",
    "ha_off_surplus_watts": "50",
    "ha_interval_seconds": "900",
    "ha_max_concurrent_on": "6",
    "ha_min_on_seconds": "600",
    "ha_min_off_seconds": "300",
}

# Runtime _state_row fallback: stale invented ids, reverse optional V/A aliases.
# Settings default to live MQTT ids; stale DB values remap in _normalize_settings_keys.
_ENTITY_ALIASES: dict[str, tuple[str, ...]] = {
    "sensor.solar_controller_solar": ("sensor.solar_controller_solar_power",),
    "sensor.solar_controller_charge_state": ("sensor.solar_controller_battery_state",),
    "sensor.battery_1_state_of_charge": ("sensor.battery_1_soc",),
    "sensor.battery_2_state_of_charge": ("sensor.battery_2_soc",),
    "sensor.solar_controller_solar_power": ("sensor.solar_controller_solar",),
    "sensor.solar_controller_battery_state": ("sensor.solar_controller_charge_state",),
    "sensor.battery_1_soc": ("sensor.battery_1_state_of_charge",),
    "sensor.battery_2_soc": ("sensor.battery_2_state_of_charge",),
    "sensor.battery_1_voltage": ("sensor.battery_1_battery_voltage",),
    "sensor.battery_2_voltage": ("sensor.battery_2_battery_voltage",),
    "sensor.battery_1_current": ("sensor.battery_1_battery_current",),
    "sensor.battery_2_current": ("sensor.battery_2_battery_current",),
    _SIM_DUMP_LOAD_ENTITY: (_LEGACY_SIM_DUMP_LOAD_ENTITY,),
}

_STALE_ENTITY_ID_REMAP: dict[str, str] = {
    "sensor.solar_controller_solar_power": "sensor.solar_controller_solar",
    "sensor.solar_controller_battery_state": "sensor.solar_controller_charge_state",
    "sensor.battery_1_soc": "sensor.battery_1_state_of_charge",
    "sensor.battery_2_soc": "sensor.battery_2_state_of_charge",
}

_ENTITY_SETTING_KEYS = (
    "ha_solar_entity",
    "ha_soc_entity",
    "ha_charge_state_entity",
)


def _normalize_settings_keys(settings: dict[str, str]) -> dict[str, str]:
    out = dict(settings)
    for old_key, new_key in _LEGACY_SETTING_KEYS.items():
        if old_key in out and new_key not in out:
            out[new_key] = str(out[old_key])
    load_entity = out.get("ha_load_entity", "")
    if load_entity == _LEGACY_SIM_DUMP_LOAD_ENTITY:
        out["ha_load_entity"] = _SIM_DUMP_LOAD_ENTITY
    for key in _ENTITY_SETTING_KEYS:
        val = out.get(key, "")
        if val in _STALE_ENTITY_ID_REMAP:
            out[key] = _STALE_ENTITY_ID_REMAP[val]
    return out


def _settings_dict(store_or_dict: Any | None) -> dict[str, str]:
    if store_or_dict is None:
        return dict(_DEFAULTS)
    if isinstance(store_or_dict, dict):
        merged = dict(_DEFAULTS)
        merged.update({k: str(v) for k, v in store_or_dict.items()})
        return _normalize_settings_keys(merged)
    if hasattr(store_or_dict, "get"):
        merged = dict(_DEFAULTS)
        for key in _DEFAULTS:
            merged[key] = str(store_or_dict.get(key, _DEFAULTS[key]))
        for old_key, new_key in _LEGACY_SETTING_KEYS.items():
            if store_or_dict.get(old_key) is not None and merged.get(new_key) == _DEFAULTS.get(
                new_key, ""
            ):
                merged[new_key] = str(store_or_dict.get(old_key))
        return _normalize_settings_keys(merged)
    return dict(_DEFAULTS)


def _parse_entity_list(raw: str) -> frozenset[str]:
    if not (raw or "").strip():
        return frozenset()
    out: set[str] = set()
    for part in raw.split(","):
        token = part.strip()
        if token:
            out.add(validate_entity_id(token))
    return frozenset(out)


_SIM_PLUG_PREFIX = "switch.sim_ac_plug_"


def load_ha_switch_allowlist(settings: Any | None = None) -> frozenset[str]:
    settings_map = _settings_dict(settings)
    return _parse_entity_list(settings_map.get("ha_switch_allowlist", ""))


def path_b_sim_dump_guardrail(settings: Any | None = None) -> tuple[bool, str]:
    """True when Path B may auto-write project sandbox files.

    Operator 2026-09-15: simulated dump-load plugs are the Path B file-write rail.
    Dump actuation does not use this function. A real house entity on the dump
    allowlist pauses Path B auto-write only. Official HA REST:
    https://developers.home-assistant.io/docs/api/rest/
    """
    if not home_assistant_enabled():
        return False, "ALFA_AI_HOME_ASSISTANT_ENABLED=0"
    if not home_assistant_ready():
        return False, "Home Assistant token or URL not ready"
    if settings is None:
        settings = _load_settings_store()
    allow = load_ha_switch_allowlist(settings)
    if not allow:
        return False, "ha_switch_allowlist empty"
    bad = sorted(eid for eid in allow if not eid.startswith(_SIM_PLUG_PREFIX))
    if bad:
        preview = ", ".join(bad[:4])
        return False, (
            f"dump allowlist includes non-sim loads ({preview}); "
            "Path B project auto-write paused"
        )
    return True, "sim dump allowlist only"


def load_ha_never_auto(settings: Any | None = None) -> frozenset[str]:
    settings_map = _settings_dict(settings)
    return _parse_entity_list(settings_map.get("ha_never_auto", ""))


def load_ha_switch_watts(settings: Any | None = None) -> dict[str, int]:
    """Parse ha_switch_watts entity_id=watts pairs (0-100000)."""
    settings_map = _settings_dict(settings)
    raw = settings_map.get("ha_switch_watts", "")
    if not (raw or "").strip():
        return {}
    out: dict[str, int] = {}
    for part in raw.split(","):
        token = part.strip()
        if not token:
            continue
        if "=" not in token:
            continue
        eid_raw, watts_raw = token.split("=", 1)
        eid = validate_entity_id(eid_raw.strip())
        try:
            watts = int(watts_raw.strip())
        except ValueError:
            continue
        if watts < 0 or watts > 100000:
            continue
        out[eid] = watts
    return out


def _sim_on_watts(
    states: dict[str, dict[str, Any]], watts_map: dict[str, int]
) -> int:
    total = 0
    for entity_id, rated_w in watts_map.items():
        if _entity_is_on(states.get(entity_id)):
            total += rated_w
    return total


def _is_sim_dump_load_entity(load_entity: str) -> bool:
    return load_entity in (_SIM_DUMP_LOAD_ENTITY, _LEGACY_SIM_DUMP_LOAD_ENTITY)


def _effective_load_watts(
    load_w: float | None,
    states: dict[str, dict[str, Any]],
    watts_map: dict[str, int],
    *,
    load_entity: str = _SIM_DUMP_LOAD_ENTITY,
) -> float | None:
    sim_w = _sim_on_watts(states, watts_map)
    if _is_sim_dump_load_entity(load_entity):
        if load_w is not None:
            return load_w
        if watts_map:
            return float(sim_w)
        return None
    if load_w is not None:
        return load_w + sim_w
    if watts_map:
        return float(sim_w)
    return None


def _setting_on(raw: str | None) -> bool:
    return (raw or "").strip().lower() in ("1", "true", "yes", "on")


def _state_row(states: dict[str, dict[str, Any]], entity_id: str) -> dict[str, Any] | None:
    row = states.get(entity_id)
    if row:
        return row
    for alias in _ENTITY_ALIASES.get(entity_id, ()):
        aliased = states.get(alias)
        if aliased:
            return aliased
    return None


def _parse_float_state(state_row: dict[str, Any] | None) -> float | None:
    if not state_row:
        return None
    raw = str(state_row.get("state") or "").strip().lower()
    if raw in ("unavailable", "unknown", "", "none", "nan"):
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def _entity_is_on(state_row: dict[str, Any] | None) -> bool:
    if not state_row:
        return False
    return str(state_row.get("state") or "").strip().lower() in ("on", "true", "1")


def _charge_ok(state_row: dict[str, Any] | None, allowed: frozenset[str]) -> bool:
    if not state_row:
        return False
    stage = str(state_row.get("state") or "").strip().lower()
    return stage in allowed


def decide_dump(
    *,
    states: dict[str, dict[str, Any]],
    settings: dict[str, str],
    now: float,
    last_toggle: dict[str, tuple[str, float]] | None = None,
) -> tuple[list[DumpDecision], dict[str, Any]]:
    """Pure dump-load decision: states + settings + now -> decisions and snapshot meta."""
    settings = _normalize_settings_keys(dict(settings))
    toggles = last_toggle if last_toggle is not None else _last_toggle
    enabled = _setting_on(settings.get("ha_solar_dump_enabled", "false"))
    allowlist = _parse_entity_list(settings.get("ha_switch_allowlist", ""))
    never_auto = _parse_entity_list(settings.get("ha_never_auto", ""))
    charge_ok_states = frozenset(
        tok.strip().lower()
        for tok in (settings.get("ha_charge_states_ok") or "").split(",")
        if tok.strip()
    )
    min_soc = int(settings.get("ha_min_soc_percent", "95"))
    min_solar = int(settings.get("ha_min_solar_watts", "50"))
    max_on = int(settings.get("ha_max_concurrent_on", "2"))
    min_on_sec = int(settings.get("ha_min_on_seconds", "600"))
    min_off_sec = int(settings.get("ha_min_off_seconds", "300"))

    solar_e = settings.get("ha_solar_entity", _DEFAULTS["ha_solar_entity"])
    load_e = settings.get("ha_load_entity", _DEFAULTS["ha_load_entity"])
    soc_e = settings.get("ha_soc_entity", _DEFAULTS["ha_soc_entity"])
    volt_e = settings.get("ha_shunt_voltage_entity", _DEFAULTS["ha_shunt_voltage_entity"])
    curr_e = settings.get("ha_shunt_current_entity", _DEFAULTS["ha_shunt_current_entity"])
    charge_e = settings.get("ha_charge_state_entity", _DEFAULTS["ha_charge_state_entity"])
    soc_unsynced = _setting_on(settings.get("ha_soc_unsynced", "true"))

    solar_w = _parse_float_state(_state_row(states, solar_e))
    load_w = _parse_float_state(_state_row(states, load_e))
    soc = _parse_float_state(_state_row(states, soc_e))
    shunt_v = _parse_float_state(_state_row(states, volt_e))
    shunt_a = _parse_float_state(_state_row(states, curr_e))
    t2_shunt_v = shunt_v
    t2_shunt_a = shunt_a
    ku_shunt_v = _parse_float_state(_state_row(states, "sensor.battery_2_voltage"))
    ku_shunt_a = _parse_float_state(_state_row(states, "sensor.battery_2_current"))
    charge_row = _state_row(states, charge_e)
    watts_map = load_ha_switch_watts(settings)
    sim_plug_w = _sim_on_watts(states, watts_map)
    effective_load_w = _effective_load_watts(
        load_w, states, watts_map, load_entity=load_e
    )

    meta: dict[str, Any] = {
        "enabled": enabled,
        "solar_w": solar_w,
        "load_w": load_w,
        "sim_plug_w": sim_plug_w,
        "effective_load_w": effective_load_w,
        "soc": soc,
        "shunt_v": shunt_v,
        "shunt_a": shunt_a,
        "t2_shunt_v": t2_shunt_v,
        "t2_shunt_a": t2_shunt_a,
        "ku_shunt_v": ku_shunt_v,
        "ku_shunt_a": ku_shunt_a,
        "soc_unsynced": soc_unsynced,
        "charge_state": str(charge_row.get("state") if charge_row else ""),
        "allowlist_count": len(allowlist),
    }

    float_v = _parse_float_state(_state_row(states, _HA_DUMP_FLOAT_HELPER))
    if float_v is None:
        float_v = _DEFAULT_FLOAT_V
    rebulk_v = _parse_float_state(_state_row(states, _HA_DUMP_REBULK_HELPER))
    if rebulk_v is None:
        rebulk_v = _DEFAULT_REBULK_V
    helper_min_solar = _parse_float_state(_state_row(states, _HA_DUMP_MIN_SOLAR_HELPER))
    if helper_min_solar is not None:
        min_solar = int(helper_min_solar)

    charge_float_row = states.get(_HA_DUMP_CHARGE_FLOAT)
    if charge_float_row:
        charge_float = _entity_is_on(charge_float_row)
    else:
        charge_float = str(charge_row.get("state") if charge_row else "").strip().lower() == "float"

    solar_present_row = states.get(_HA_DUMP_SOLAR_PRESENT)
    if solar_present_row:
        solar_present = _entity_is_on(solar_present_row)
    else:
        solar_present = solar_w is not None and solar_w >= min_solar

    rebulk_row = states.get(_HA_DUMP_V_REBULK_T2)
    if rebulk_row:
        rebulk_hit = _entity_is_on(rebulk_row)
    else:
        rebulk_hit = shunt_v is not None and shunt_v <= rebulk_v

    float_hold_row = states.get(_HA_DUMP_V_FLOAT_T2)
    if float_hold_row:
        float_hold = _entity_is_on(float_hold_row)
    else:
        float_hold = shunt_v is None or shunt_v >= float_v

    soc_ok_row = states.get(_HA_DUMP_SOC_OK)
    if soc_ok_row:
        soc_ok = _entity_is_on(soc_ok_row)
    elif soc_unsynced:
        soc_ok = True
        meta["soc_gate"] = "skipped_unsynced"
    elif soc is None or soc < min_soc:
        soc_ok = False
    else:
        soc_ok = True

    meta["float_v"] = float_v
    meta["rebulk_v"] = rebulk_v
    meta["min_solar_w"] = min_solar
    meta["charge_float"] = charge_float
    meta["solar_present"] = solar_present
    meta["float_hold"] = float_hold
    meta["rebulk_hit"] = rebulk_hit
    meta["soc_ok"] = soc_ok

    surplus: float | None = None
    if solar_w is not None and effective_load_w is not None:
        surplus = solar_w - effective_load_w
        meta["surplus_w"] = surplus
    decision_surplus = apply_ledger_to_meta(meta, states, surplus)

    if not enabled:
        return [], {**meta, "skipped": "ha_solar_dump_enabled=false"}

    if not allowlist:
        return [], {**meta, "skipped": "empty ha_switch_allowlist"}

    if solar_w is None:
        return [], {**meta, "skipped": "solar sensor unavailable"}

    if soc_ok_row is None:
        if soc_unsynced:
            meta["soc_gate"] = "skipped_unsynced"
        elif soc is None or soc < min_soc:
            return [], {**meta, "skipped": f"soc below {min_soc}"}

    if not soc_ok:
        return [], {**meta, "skipped": f"soc below {min_soc}"}

    want_off_all = (not solar_present) or (not charge_float) or rebulk_hit
    want_on = (
        (not want_off_all)
        and solar_present
        and charge_float
        and float_hold
        and soc_ok
    )
    meta["want_off_all"] = want_off_all
    meta["want_on"] = want_on
    meta["surplus_after_path_losses_w"] = decision_surplus

    eligible = [e for e in sorted(allowlist) if e not in never_auto]
    concurrent_on = sum(1 for e in eligible if _entity_is_on(states.get(e)))

    decisions: list[DumpDecision] = []
    on_recommended = 0
    for entity_id in eligible:
        current_on = _entity_is_on(states.get(entity_id))
        target: Literal["on", "off", "skip"] = "skip"
        reason = "float band hold"

        if want_off_all:
            target = "off"
            if not solar_present:
                reason = f"solar gone (PV < {min_solar} W)"
            elif rebulk_hit:
                reason = f"re-bulk V <= {rebulk_v} V"
            else:
                reason = f"charge state not in {','.join(sorted(charge_ok_states))}"
        elif want_on:
            target = "on"
            reason = (
                f"float hold V>={float_v} V and solar present "
                f"(surplus {surplus if surplus is not None else 'n/a'} W briefing only)"
            )

        if target == "on" and current_on:
            decisions.append((entity_id, "skip", "already on"))
            continue
        if target == "off" and not current_on:
            decisions.append((entity_id, "skip", "already off"))
            continue
        if target == "skip":
            decisions.append((entity_id, "skip", reason))
            continue

        last = toggles.get(entity_id)
        if last and not want_off_all:
            last_action, last_ts = last
            elapsed = now - last_ts
            if target == "off" and last_action == "on" and elapsed < min_on_sec:
                decisions.append(
                    (entity_id, "skip", f"min_on {min_on_sec}s not met ({elapsed:.0f}s)")
                )
                continue
            if target == "on" and last_action == "off" and elapsed < min_off_sec:
                decisions.append(
                    (entity_id, "skip", f"min_off {min_off_sec}s not met ({elapsed:.0f}s)")
                )
                continue

        if target == "on" and not current_on:
            if on_recommended >= 1:
                decisions.append((entity_id, "skip", "staged one plug per tick"))
                continue
            if concurrent_on >= max_on:
                decisions.append(
                    (entity_id, "skip", f"max_concurrent_on {max_on} reached")
                )
                continue

        decisions.append((entity_id, target, reason))
        if target == "on" and not current_on:
            concurrent_on += 1
            on_recommended += 1

    return decisions, meta


def _dump_entity_lists(
    settings: dict[str, str],
) -> tuple[list[str], list[str]]:
    """Return (required_ids, optional_fetch_ids) for HA state collection."""
    settings = _normalize_settings_keys(settings)
    required_keys: list[str] = [
        "ha_solar_entity",
        "ha_load_entity",
        "ha_charge_state_entity",
    ]
    if not _setting_on(settings.get("ha_soc_unsynced", "true")):
        required_keys.append("ha_soc_entity")

    required: list[str] = []
    optional: list[str] = []
    seen: set[str] = set()

    def _append(eid: str, bucket: list[str]) -> None:
        valid = validate_entity_id(eid)
        if valid in seen:
            return
        seen.add(valid)
        bucket.append(valid)

    for key in required_keys:
        eid = settings.get(key, _DEFAULTS[key])
        _append(eid, required)
        for alias in _ENTITY_ALIASES.get(eid, ()):
            _append(alias, optional)

    for key in ("ha_shunt_voltage_entity", "ha_shunt_current_entity"):
        eid = settings.get(key, _DEFAULTS[key])
        _append(eid, optional)
        for alias in _ENTITY_ALIASES.get(eid, ()):
            _append(alias, optional)

    for eid in ("sensor.battery_2_voltage", "sensor.battery_2_current"):
        _append(eid, optional)
        for alias in _ENTITY_ALIASES.get(eid, ()):
            _append(alias, optional)

    for eid in (
        _HA_DUMP_FLOAT_HELPER,
        _HA_DUMP_REBULK_HELPER,
        _HA_DUMP_MIN_SOLAR_HELPER,
        _HA_DUMP_CHARGE_FLOAT,
        _HA_DUMP_SOLAR_PRESENT,
        _HA_DUMP_V_FLOAT_T2,
        _HA_DUMP_V_REBULK_T2,
        _HA_DUMP_SOC_OK,
    ):
        _append(eid, optional)

    return required, optional


def _dump_sensor_entities(settings: dict[str, str]) -> list[str]:
    """Flat fetch list for Ask ALFa inspect (required dump sensors + optional ledger ids)."""
    required, optional = _dump_entity_lists(settings)
    return list(dict.fromkeys([*required, *optional]))


async def _observe_weather(settings: dict[str, str]) -> dict[str, Any]:
    """Current outdoor weather + daily forecast for audit/Ask ALFa. Not used by decide_dump."""
    raw = (settings.get("ha_weather_entity") or "").strip()
    if not raw:
        return {"weather_skipped": "ha_weather_entity empty"}
    try:
        eid = validate_weather_entity_id(raw)
    except ValueError as exc:
        return {"weather_skipped": str(exc)}
    out: dict[str, Any] = {"weather_entity": eid}
    try:
        row = await ha_get_state(eid)
    except HomeAssistantError as exc:
        out["weather_skipped"] = str(exc)
        return out
    attrs = row.get("attributes") if isinstance(row.get("attributes"), dict) else {}
    out["weather_condition"] = row.get("state")
    if "temperature" in attrs:
        out["weather_temperature"] = attrs.get("temperature")
    if "humidity" in attrs:
        out["weather_humidity"] = attrs.get("humidity")
    try:
        payload = await ha_get_forecasts(eid, "daily")
        entries = compact_forecast_entries(
            forecast_entries_from_response(payload, eid), limit=5
        )
        out["weather_forecast_daily"] = entries
    except HomeAssistantError as exc:
        out["weather_forecast_skipped"] = str(exc)
    return out


def _load_settings_store() -> Any | None:
    db_url = (os.getenv("DATABASE_URL") or "").strip()
    if not db_url:
        return None
    try:
        from src.api.models.ai_setting import AiSettingStore

        return AiSettingStore(db_url)
    except Exception:
        logger.exception("solar_dump: AiSettingStore unavailable")
        return None


def _now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


def _entity_resolved(entity_id: str, states: dict[str, dict[str, Any]]) -> bool:
    return _state_row(states, entity_id) is not None


def _missing_entity_ids(
    required: list[str], states: dict[str, dict[str, Any]]
) -> list[str]:
    return [eid for eid in required if not _entity_resolved(eid, states)]


def _build_thinking(
    *,
    missing: list[str],
    states: dict[str, dict[str, Any]],
    meta: dict[str, Any],
    decisions: list[DumpDecision],
) -> list[str]:
    """Programmatic decision trace for audit/UI (not LLM)."""
    lines: list[str] = []
    for eid in missing:
        lines.append(f"missing entity {eid}")
    solar_w = meta.get("solar_w")
    if solar_w is not None:
        lines.append(f"solar_w={solar_w}")
    surplus = meta.get("surplus_w")
    if surplus is not None:
        lines.append(f"surplus_w={surplus}")
    soc_gate = meta.get("soc_gate")
    if soc_gate:
        lines.append(f"soc_gate={soc_gate}")
    skipped = meta.get("skipped")
    if skipped:
        lines.append(f"skip: {skipped}")
    for entity_id, action, reason in decisions:
        if action != "skip":
            lines.append(f"{action} {entity_id}: {reason}")
    return lines


def _record_action(action_type: str, summary: str, detail: dict[str, Any]) -> None:
    db_url = (os.getenv("DATABASE_URL") or "").strip()
    if not db_url:
        return
    try:
        from src.api.models.ai_action import AiActionStore

        AiActionStore(db_url).record(
            action_type,
            summary,
            detail=detail,
            created_by="program",
        )
    except Exception:
        logger.exception("solar_dump: failed to record ai_action %s", action_type)


async def run_dump_tick(*, actuate: bool) -> dict[str, Any]:
    """Fetch HA states, record dump comparison, always audit. Never POSTs switch services."""
    global _last_dump_summary, _consecutive_http_failures

    store = _load_settings_store()
    settings = _settings_dict(store)
    required_entities, optional_entities = _dump_entity_lists(settings)
    allowlist = _parse_entity_list(settings.get("ha_switch_allowlist", ""))
    fetch_ids = list(
        dict.fromkeys([*required_entities, *optional_entities, *sorted(allowlist)])
    )
    missing_check_ids = list(dict.fromkeys([*required_entities, *sorted(allowlist)]))

    recorded_at = _now_iso()
    result: dict[str, Any] = {
        "ok": True,
        "decisions": [],
        "meta": {},
        "recorded_at": recorded_at,
    }
    try:
        rows = await ha_get_states(fetch_ids, require_all=False)
        _consecutive_http_failures = 0
    except HomeAssistantError as exc:
        _consecutive_http_failures += 1
        if _consecutive_http_failures >= 5:
            logger.warning(
                "solar_dump: %d consecutive HA failures",
                _consecutive_http_failures,
            )
        result["ok"] = False
        result["error"] = str(exc)
        _record_action(
            ACTION_SOLAR_DUMP_OBSERVED,
            f"solar dump tick skipped: {exc}",
            {
                "ok": False,
                "skipped": str(exc),
                "failures": _consecutive_http_failures,
                "requested_entity_ids": fetch_ids,
                "decisions": [],
            },
        )
        _last_dump_summary = result
        return result

    states = {str(r.get("entity_id") or ""): r for r in rows}
    missing = _missing_entity_ids(missing_check_ids, states)
    now = time.time()
    decisions, meta = decide_dump(states=states, settings=settings, now=now)
    if missing:
        meta["missing_entity_ids"] = missing
    auto_actuate = False
    if actuate:
        logger.info(
            "solar_dump: ignoring actuate=True; Home Assistant automations own dump switches"
        )

    result["decisions"] = [
        {"entity_id": e, "action": a, "reason": r} for e, a, r in decisions
    ]
    weather_meta = await _observe_weather(settings)
    meta.update(weather_meta)
    meta["thinking"] = _build_thinking(
        missing=missing,
        states=states,
        meta=meta,
        decisions=decisions,
    )
    result["meta"] = meta

    _record_action(
        ACTION_SOLAR_DUMP_OBSERVED,
        f"solar dump observed surplus={meta.get('surplus_w')}W allowlist={meta.get('allowlist_count')}",
        {
            "ok": True,
            "meta": meta,
            "decisions": result["decisions"],
        },
    )

    for entity_id, action, reason in decisions:
        if action == "skip":
            continue
        _record_action(
            ACTION_SOLAR_DUMP_RECOMMENDED,
            f"solar dump would {action} {entity_id}: {reason}",
            {
                "entity_id": entity_id,
                "action": action,
                "reason": reason,
                "auto_actuate": auto_actuate,
            },
        )

    _last_dump_summary = result
    return result


def get_last_dump_summary() -> dict[str, Any] | None:
    return _last_dump_summary


def _hop_stored_w(meta: dict[str, Any], hop_id: str) -> float | None:
    hops = meta.get("watt_hops")
    if not isinstance(hops, list):
        return None
    for hop in hops:
        if not isinstance(hop, dict) or hop.get("id") != hop_id:
            continue
        val = hop.get("stored_w")
        if isinstance(val, bool) or not isinstance(val, (int, float)):
            return None
        return float(val)
    return None


def build_home_energy_ops_context(settings: Any | None = None) -> dict[str, Any]:
    if not home_assistant_enabled():
        return {"enabled": False}
    settings_map = _settings_dict(settings)
    allowlist = load_ha_switch_allowlist(settings)
    summary = get_last_dump_summary() or {}
    meta = summary.get("meta") if isinstance(summary.get("meta"), dict) else {}
    return {
        "enabled": True,
        "ha_ready": home_assistant_ready(),
        "dump_enabled": settings_map.get("ha_solar_dump_enabled") == "true",
        "auto_actuate": False,
        "allowlist_count": len(allowlist),
        "last_surplus_w": meta.get("surplus_w"),
        "last_jumper_w": meta.get("jumper_w"),
        "last_batt2_stored_w": _hop_stored_w(meta, "ku_battery"),
        "last_shunt_a": meta.get("shunt_a"),
        "last_t2_shunt_a": meta.get("t2_shunt_a"),
        "last_ku_shunt_a": meta.get("ku_shunt_a"),
        "last_combined_losses_w": meta.get("combined_losses_w"),
        "last_combined_vdrop_loss_w": meta.get("combined_vdrop_loss_w"),
        "last_combined_path_losses_w": meta.get("combined_path_losses_w"),
        "last_surplus_after_path_losses_w": meta.get("surplus_after_path_losses_w"),
        "last_vent_fan_w": meta.get("vent_fan_w"),
        "last_weather_condition": meta.get("weather_condition"),
        "last_weather_temperature": meta.get("weather_temperature"),
        "last_weather_forecast_daily": meta.get("weather_forecast_daily"),
        "last_skipped": meta.get("skipped"),
    }


async def run_solar_dump_loop(stop: asyncio.Event) -> None:
    """Background ticker; sleeps ha_interval_seconds between ticks."""
    while not stop.is_set():
        interval = 900
        if home_assistant_enabled():
            store = _load_settings_store()
            settings = _settings_dict(store)
            try:
                raw = int(settings.get("ha_interval_seconds", "900"))
                interval = max(60, min(raw, 3600))
            except ValueError:
                interval = 900
            if home_assistant_ready() and settings.get("ha_solar_dump_enabled") == "true":
                try:
                    await run_dump_tick(actuate=False)
                except Exception:
                    logger.exception("solar_dump tick failed")
        try:
            await asyncio.wait_for(stop.wait(), timeout=interval)
        except asyncio.TimeoutError:
            continue
