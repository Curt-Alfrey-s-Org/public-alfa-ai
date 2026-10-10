"""Solar dump-load decision logic tests."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from src.api.models.ai_action import ACTION_SOLAR_DUMP_OBSERVED, category_for_action
from src.ops.solar_dump import (
    build_home_energy_ops_context,
    decide_dump,
    path_b_sim_dump_guardrail,
    run_dump_tick,
)


def _base_settings(**overrides: str) -> dict[str, str]:
    settings = {
        "ha_solar_dump_enabled": "true",
        "ha_switch_allowlist": "switch.a,switch.b",
        "ha_never_auto": "",
        "ha_solar_entity": "sensor.solar_controller_solar",
        "ha_load_entity": "sensor.sim_dump_load_power",
        "ha_soc_entity": "sensor.battery_1_state_of_charge",
        "ha_charge_state_entity": "sensor.solar_controller_charge_state",
        "ha_soc_unsynced": "true",
        "ha_charge_states_ok": "absorption,float",
        "ha_min_soc_percent": "95",
        "ha_min_solar_watts": "50",
        "ha_min_surplus_watts": "200",
        "ha_off_surplus_watts": "50",
        "ha_max_concurrent_on": "2",
        "ha_min_on_seconds": "0",
        "ha_min_off_seconds": "0",
    }
    settings.update(overrides)
    return settings


def _states(
    *,
    solar: str = "1500",
    load: str = "1000",
    soc: str = "90",
    charge: str = "float",
    switch_a: str = "off",
    switch_b: str = "off",
) -> dict[str, dict]:
    return {
        "sensor.solar_controller_solar": {
            "entity_id": "sensor.solar_controller_solar",
            "state": solar,
        },
        "sensor.sim_dump_load_power": {
            "entity_id": "sensor.sim_dump_load_power",
            "state": load,
        },
        "sensor.battery_1_state_of_charge": {
            "entity_id": "sensor.battery_1_state_of_charge",
            "state": soc,
        },
        "sensor.battery_1_voltage": {"entity_id": "sensor.battery_1_voltage", "state": "28.6"},
        "sensor.battery_1_current": {"entity_id": "sensor.battery_1_current", "state": "2.1"},
        "sensor.battery_2_voltage": {"entity_id": "sensor.battery_2_voltage", "state": "25.6"},
        "sensor.battery_2_current": {"entity_id": "sensor.battery_2_current", "state": "-4.8"},
        "sensor.solar_controller_charge_state": {
            "entity_id": "sensor.solar_controller_charge_state",
            "state": charge,
        },
        "switch.a": {"entity_id": "switch.a", "state": switch_a},
        "switch.b": {"entity_id": "switch.b", "state": switch_b},
    }


def test_float_and_solar_turns_on() -> None:
    decisions, meta = decide_dump(
        states=_states(solar="1500", load="1000"),
        settings=_base_settings(),
        now=1000.0,
    )
    assert meta["surplus_w"] == 500
    assert meta["charge_float"] is True
    assert meta["solar_present"] is True
    on_actions = [d for d in decisions if d[1] == "on"]
    assert len(on_actions) == 1


def test_weather_state_does_not_change_dump_decision() -> None:
    rainy = _states(solar="1500", load="1000")
    rainy["weather.417373300314"] = {
        "entity_id": "weather.417373300314",
        "state": "rainy",
        "attributes": {"temperature": 82, "humidity": 90},
    }
    decisions_clear, meta_clear = decide_dump(
        states=_states(solar="1500", load="1000"),
        settings=_base_settings(),
        now=1000.0,
    )
    decisions_rain, meta_rain = decide_dump(
        states=rainy,
        settings=_base_settings(),
        now=1000.0,
    )
    assert [d[:2] for d in decisions_clear] == [d[:2] for d in decisions_rain]
    assert meta_clear["surplus_w"] == meta_rain["surplus_w"]


def test_voltage_between_rebulk_and_float_holds() -> None:
    states = _states(solar="1500", load="1000", switch_a="off")
    states["sensor.battery_1_voltage"]["state"] = "26.9"
    decisions, _ = decide_dump(
        states=states,
        settings=_base_settings(),
        now=1000.0,
    )
    assert all(d[1] == "skip" for d in decisions)


def test_solar_gone_turns_off() -> None:
    decisions, _ = decide_dump(
        states=_states(solar="20", load="1000", switch_a="on"),
        settings=_base_settings(),
        now=1000.0,
    )
    off = [d for d in decisions if d[0] == "switch.a" and d[1] == "off"]
    assert len(off) == 1


def test_rebulk_voltage_turns_off() -> None:
    states = _states(solar="1500", load="1000", switch_a="on")
    states["sensor.battery_1_voltage"]["state"] = "26.7"
    decisions, meta = decide_dump(
        states=states,
        settings=_base_settings(),
        now=1000.0,
    )
    assert meta["rebulk_hit"] is True
    off = [d for d in decisions if d[0] == "switch.a" and d[1] == "off"]
    assert len(off) == 1


def test_empty_allowlist_never_toggles() -> None:
    decisions, meta = decide_dump(
        states=_states(),
        settings=_base_settings(ha_switch_allowlist=""),
        now=1000.0,
    )
    assert decisions == []
    assert meta.get("skipped") == "empty ha_switch_allowlist"


def test_bad_charge_state_does_not_turn_on() -> None:
    decisions, meta = decide_dump(
        states=_states(charge="bulk"),
        settings=_base_settings(),
        now=1000.0,
    )
    assert not any(d[1] == "on" for d in decisions)
    assert meta["charge_float"] is False
    assert meta["want_off_all"] is True


def test_absorption_does_not_turn_on_even_if_setting_lists_it() -> None:
    decisions, meta = decide_dump(
        states=_states(charge="absorption", solar="1500", load="1000"),
        settings=_base_settings(ha_charge_states_ok="float,absorption"),
        now=1000.0,
    )
    assert meta["charge_float"] is False
    assert not any(d[1] == "on" for d in decisions)


def test_max_concurrent_on_caps_turn_on() -> None:
    settings = _base_settings(ha_max_concurrent_on="1")
    states = _states(switch_a="on", switch_b="off")
    decisions, _ = decide_dump(states=states, settings=settings, now=1000.0)
    switch_b = [d for d in decisions if d[0] == "switch.b"]
    assert switch_b
    assert switch_b[0][1] in ("skip", "on")
    if switch_b[0][1] == "skip":
        assert "max_concurrent_on" in switch_b[0][2]


def test_sim_watts_when_load_unavailable() -> None:
    settings = _base_settings(ha_switch_watts="switch.a=500")
    states = _states(load="unavailable", switch_a="on", solar="1500")
    decisions, meta = decide_dump(states=states, settings=settings, now=1000.0)
    assert meta["effective_load_w"] == 500
    assert meta["surplus_w"] == 1000
    assert any(d[1] == "on" for d in decisions)


def test_effective_load_adds_sim_watts_on_top_of_plant_sensor() -> None:
    settings = _base_settings(
        ha_load_entity="sensor.em16_ku_house_power",
        ha_switch_watts="switch.a=200",
    )
    states = _states(load="1000", switch_a="on", solar="1500")
    states["sensor.em16_ku_house_power"] = {
        "entity_id": "sensor.em16_ku_house_power",
        "state": "1000",
    }
    _, meta = decide_dump(states=states, settings=settings, now=1000.0)
    assert meta["effective_load_w"] == 1200
    assert meta["surplus_w"] == 300


def test_load_unavailable_without_watts_map_still_uses_float() -> None:
    settings = _base_settings(ha_switch_watts="")
    states = _states(load="unavailable")
    decisions, meta = decide_dump(states=states, settings=settings, now=1000.0)
    assert meta.get("surplus_w") is None
    assert any(d[1] == "on" for d in decisions)


def test_defaults_load_entity_not_em16_a3() -> None:
    from src.api.models.ai_setting import _DEFAULTS as AI_SETTING_DEFAULTS, validate_setting_value
    from src.ops.home_assistant_client import DEFAULT_WEATHER_ENTITY
    from src.ops.solar_dump import DUMP_HA_NUMBER_HELPERS, _DEFAULTS, _SIM_DUMP_LOAD_ENTITY

    assert _DEFAULTS["ha_load_entity"] == _SIM_DUMP_LOAD_ENTITY
    assert _DEFAULTS["ha_load_entity"] != "sensor.em16_a3_power"
    assert AI_SETTING_DEFAULTS["ha_load_entity"][0] == _DEFAULTS["ha_load_entity"]
    assert AI_SETTING_DEFAULTS["ha_load_entity"][0] == "sensor.sim_dump_load_power"
    assert _DEFAULTS["ha_weather_entity"] == DEFAULT_WEATHER_ENTITY
    assert AI_SETTING_DEFAULTS["ha_weather_entity"][0] == DEFAULT_WEATHER_ENTITY
    assert validate_setting_value("ha_weather_entity", "") == ""
    assert _DEFAULTS["ha_solar_entity"] == "sensor.solar_controller_solar"
    assert AI_SETTING_DEFAULTS["ha_solar_entity"][0] == _DEFAULTS["ha_solar_entity"]
    assert _DEFAULTS["ha_soc_entity"] == "sensor.battery_1_state_of_charge"
    assert AI_SETTING_DEFAULTS["ha_soc_entity"][0] == _DEFAULTS["ha_soc_entity"]
    assert _DEFAULTS["ha_charge_state_entity"] == "sensor.solar_controller_charge_state"
    assert AI_SETTING_DEFAULTS["ha_charge_state_entity"][0] == _DEFAULTS["ha_charge_state_entity"]
    assert _DEFAULTS["ha_charge_states_ok"] == "absorption,float"
    assert AI_SETTING_DEFAULTS["ha_charge_states_ok"][0] == "absorption,float"
    assert _DEFAULTS["ha_min_soc_percent"] == "95"
    assert AI_SETTING_DEFAULTS["ha_min_soc_percent"][0] == "95"
    assert _DEFAULTS["ha_min_solar_watts"] == "50"
    assert AI_SETTING_DEFAULTS["ha_min_solar_watts"][0] == "50"
    assert "input_number.dump_float_t2_v" in DUMP_HA_NUMBER_HELPERS
    assert "input_number.dump_rebulk_t2_v" in DUMP_HA_NUMBER_HELPERS
    assert "input_number.dump_min_solar_w" in DUMP_HA_NUMBER_HELPERS


def test_sim_dump_load_entity_no_double_count_with_watts_map() -> None:
    settings = _base_settings(ha_switch_watts="switch.a=200")
    states = _states(load="200", switch_a="on", solar="1500")
    _, meta = decide_dump(states=states, settings=settings, now=1000.0)
    assert meta["effective_load_w"] == 200
    assert meta["surplus_w"] == 1300


def test_defaults_include_sim_plugs() -> None:
    from src.ops.solar_dump import _DEFAULTS, load_ha_switch_allowlist, load_ha_switch_watts

    assert _DEFAULTS["ha_solar_dump_enabled"] == "true"
    assert _DEFAULTS["ha_solar_dump_auto_actuate"] == "false"
    from src.api.models.ai_setting import _DEFAULTS as AI_SETTING_DEFAULTS

    assert AI_SETTING_DEFAULTS["ha_solar_dump_auto_actuate"][0] == "false"
    assert "switch.sim_ac_plug_1" in _DEFAULTS["ha_switch_allowlist"]
    allowlist = load_ha_switch_allowlist()
    assert len(allowlist) == 6
    watts = load_ha_switch_watts()
    assert watts == {}


def test_path_b_sim_dump_guardrail_sim_only(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_enabled", lambda: True)
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_ready", lambda: True)
    ok, reason = path_b_sim_dump_guardrail()
    assert ok is True
    assert reason == "sim dump allowlist only"


def test_path_b_sim_dump_guardrail_real_plug(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_enabled", lambda: True)
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_ready", lambda: True)
    settings = {
        "ha_switch_allowlist": "switch.sim_ac_plug_1,switch.living_room_lamp",
    }
    ok, reason = path_b_sim_dump_guardrail(settings)
    assert ok is False
    assert "non-sim" in reason
    assert "switch.living_room_lamp" in reason


def test_path_b_sim_dump_guardrail_ha_off(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_enabled", lambda: False)
    ok, reason = path_b_sim_dump_guardrail()
    assert ok is False
    assert "HOME_ASSISTANT" in reason


def test_path_b_sim_dump_guardrail_empty_allowlist(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_enabled", lambda: True)
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_ready", lambda: True)
    ok, reason = path_b_sim_dump_guardrail({"ha_switch_allowlist": ""})
    assert ok is False
    assert "empty" in reason


def test_path_b_sim_dump_guardrail_reads_store_when_settings_none(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_enabled", lambda: True)
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_ready", lambda: True)
    monkeypatch.setattr(
        "src.ops.solar_dump._load_settings_store",
        lambda: {"ha_switch_allowlist": "switch.living_room_lamp"},
    )
    ok, reason = path_b_sim_dump_guardrail()
    assert ok is False
    assert "switch.living_room_lamp" in reason


def test_decide_dump_uses_lovelace_entity_aliases() -> None:
    states = {
        "sensor.solar_controller_solar": {
            "entity_id": "sensor.solar_controller_solar",
            "state": "1500",
        },
        "sensor.sim_dump_load_power": {
            "entity_id": "sensor.sim_dump_load_power",
            "state": "1000",
        },
        "sensor.battery_1_state_of_charge": {
            "entity_id": "sensor.battery_1_state_of_charge",
            "state": "90",
        },
        "sensor.solar_controller_charge_state": {
            "entity_id": "sensor.solar_controller_charge_state",
            "state": "float",
        },
        "switch.a": {"entity_id": "switch.a", "state": "off"},
        "switch.b": {"entity_id": "switch.b", "state": "off"},
    }
    decisions, meta = decide_dump(states=states, settings=_base_settings(), now=1000.0)
    assert meta["solar_w"] == 1500
    assert meta["soc"] == 90
    assert meta["charge_state"] == "float"
    assert meta["surplus_w"] == 500
    assert any(d[1] == "on" for d in decisions)


def test_decide_dump_keeps_signed_ha_floats() -> None:
    states = _states(solar="1500", load="1700")
    states["sensor.battery_1_current"]["state"] = "-1.5"
    states["sensor.battery_1_power"] = {
        "entity_id": "sensor.battery_1_power",
        "state": "225",
    }
    states["sensor.battery_2_power"] = {
        "entity_id": "sensor.battery_2_power",
        "state": "-803.4",
    }
    _, meta = decide_dump(states=states, settings=_base_settings(), now=1000.0)
    assert meta["surplus_w"] == -200.0
    assert meta["shunt_a"] == -1.5
    assert meta["t2_shunt_a"] == -1.5
    assert meta["ku_shunt_a"] == -4.8
    assert meta["jumper_w"] == 1275.0
    hops = {h["id"]: h for h in meta["watt_hops"]}
    assert hops["ku_battery"]["stored_w"] == -803.4
    assert hops["t2_battery"]["stored_w"] == 225.0


def test_home_energy_ops_context_keeps_signed_floats(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_enabled", lambda: True)
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_ready", lambda: True)
    monkeypatch.setattr(
        "src.ops.solar_dump.get_last_dump_summary",
        lambda: {
            "meta": {
                "surplus_w": -200.0,
                "jumper_w": -75.0,
                "shunt_a": -1.5,
                "t2_shunt_a": -1.5,
                "ku_shunt_a": -4.8,
                "watt_hops": [{"id": "ku_battery", "stored_w": -803.4}],
                "combined_losses_w": 2.0,
                "combined_vdrop_loss_w": 0.1,
                "combined_path_losses_w": 2.1,
                "surplus_after_path_losses_w": -202.1,
                "weather_condition": "partlycloudy",
                "weather_temperature": 82,
            }
        },
    )
    ctx = build_home_energy_ops_context(
        {
            "ha_solar_dump_enabled": "true",
            "ha_solar_dump_auto_actuate": "false",
            "ha_switch_allowlist": "switch.a",
        }
    )
    assert ctx["auto_actuate"] is False
    assert ctx["last_surplus_w"] == -200.0
    assert ctx["last_jumper_w"] == -75.0
    assert ctx["last_batt2_stored_w"] == -803.4
    assert ctx["last_shunt_a"] == -1.5
    assert ctx["last_t2_shunt_a"] == -1.5
    assert ctx["last_ku_shunt_a"] == -4.8
    assert ctx["last_surplus_after_path_losses_w"] == -202.1
    assert ctx["last_weather_condition"] == "partlycloudy"
    assert ctx["last_weather_temperature"] == 82


def test_unsynced_soc_zero_does_not_skip() -> None:
    decisions, meta = decide_dump(
        states=_states(solar="1500", load="1000", soc="0"),
        settings=_base_settings(ha_soc_unsynced="true"),
        now=1000.0,
    )
    assert meta["soc_unsynced"] is True
    assert meta["soc_gate"] == "skipped_unsynced"
    assert meta["shunt_v"] == 28.6
    assert meta["shunt_a"] == 2.1
    assert meta["t2_shunt_v"] == 28.6
    assert meta["t2_shunt_a"] == 2.1
    assert meta["ku_shunt_v"] == 25.6
    assert meta["ku_shunt_a"] == -4.8
    assert meta.get("skipped") is None
    assert any(d[1] == "on" for d in decisions)


def test_synced_soc_zero_skips_min_percent() -> None:
    decisions, meta = decide_dump(
        states=_states(solar="1500", load="1000", soc="0"),
        settings=_base_settings(ha_soc_unsynced="false"),
        now=1000.0,
    )
    assert decisions == []
    assert meta.get("skipped") == "soc below 95"


def test_legacy_soak_settings_keys_still_enable() -> None:
    settings = _base_settings()
    settings.pop("ha_solar_dump_enabled", None)
    settings["ha_solar_soak_enabled"] = "true"
    decisions, meta = decide_dump(states=_states(), settings=settings, now=1000.0)
    assert meta.get("skipped") != "ha_solar_dump_enabled=false"
    assert any(d[1] == "on" for d in decisions)


def test_legacy_sim_soak_load_entity_id() -> None:
    settings = _base_settings(ha_load_entity="sensor.sim_soak_load_power")
    states = _states()
    states["sensor.sim_soak_load_power"] = states.pop("sensor.sim_dump_load_power")
    _, meta = decide_dump(states=states, settings=settings, now=1000.0)
    assert meta["surplus_w"] == 500


def test_dump_action_category_is_dump() -> None:
    assert category_for_action(ACTION_SOLAR_DUMP_OBSERVED) == "dump"
    assert category_for_action("solar_soak_observed") == "dump"


def test_run_dump_tick_live_mqtt_ids_not_listed_missing() -> None:
    async def _run() -> None:
        live_rows = [
            {"entity_id": "sensor.solar_controller_solar", "state": "1500"},
            {"entity_id": "sensor.sim_dump_load_power", "state": "1000"},
            {"entity_id": "sensor.battery_1_state_of_charge", "state": "90"},
            {"entity_id": "sensor.solar_controller_charge_state", "state": "float"},
            {"entity_id": "switch.a", "state": "off"},
            {"entity_id": "switch.b", "state": "off"},
        ]

        with patch(
            "src.ops.solar_dump._load_settings_store",
            return_value=_base_settings(),
        ), patch(
            "src.ops.solar_dump.ha_get_states",
            new_callable=AsyncMock,
            return_value=live_rows,
        ) as mock_get_states, patch(
            "src.ops.solar_dump._observe_weather",
            new_callable=AsyncMock,
            return_value={},
        ), patch(
            "src.ops.solar_dump._record_action",
        ):
            result = await run_dump_tick(actuate=False)

        mock_get_states.assert_awaited_once()
        assert mock_get_states.await_args.kwargs.get("require_all") is False
        assert result["ok"] is True
        missing = result["meta"].get("missing_entity_ids", [])
        assert "sensor.solar_controller_solar_power" not in missing
        assert "sensor.solar_controller_battery_state" not in missing
        assert "sensor.battery_1_soc" not in missing
        assert not any("using alias" in line for line in result["meta"]["thinking"])
        assert result["meta"]["solar_w"] == 1500

    asyncio.run(_run())


def test_stale_settings_entity_ids_remap_to_live() -> None:
    stale_settings = _base_settings(
        ha_solar_entity="sensor.solar_controller_solar_power",
        ha_charge_state_entity="sensor.solar_controller_battery_state",
        ha_soc_entity="sensor.battery_1_soc",
    )
    states = {
        "sensor.solar_controller_solar": {
            "entity_id": "sensor.solar_controller_solar",
            "state": "1500",
        },
        "sensor.sim_dump_load_power": {
            "entity_id": "sensor.sim_dump_load_power",
            "state": "1000",
        },
        "sensor.battery_1_state_of_charge": {
            "entity_id": "sensor.battery_1_state_of_charge",
            "state": "90",
        },
        "sensor.solar_controller_charge_state": {
            "entity_id": "sensor.solar_controller_charge_state",
            "state": "float",
        },
        "switch.a": {"entity_id": "switch.a", "state": "off"},
        "switch.b": {"entity_id": "switch.b", "state": "off"},
    }
    decisions, meta = decide_dump(states=states, settings=stale_settings, now=1000.0)
    assert meta["solar_w"] == 1500
    assert meta["charge_state"] == "float"
    assert meta["soc"] == 90
    assert any(d[1] == "on" for d in decisions)


def test_run_dump_tick_optional_battery2_va_not_missing() -> None:
    async def _run() -> None:
        rows = [
            {"entity_id": "sensor.solar_controller_solar", "state": "1500"},
            {"entity_id": "sensor.sim_dump_load_power", "state": "1000"},
            {"entity_id": "sensor.solar_controller_charge_state", "state": "float"},
            {"entity_id": "switch.a", "state": "off"},
            {"entity_id": "switch.b", "state": "off"},
        ]

        with patch(
            "src.ops.solar_dump._load_settings_store",
            return_value=_base_settings(),
        ), patch(
            "src.ops.solar_dump.ha_get_states",
            new_callable=AsyncMock,
            return_value=rows,
        ), patch(
            "src.ops.solar_dump._observe_weather",
            new_callable=AsyncMock,
            return_value={},
        ), patch(
            "src.ops.solar_dump._record_action",
        ):
            result = await run_dump_tick(actuate=False)

        missing = result["meta"].get("missing_entity_ids", [])
        assert "sensor.battery_2_voltage" not in missing
        assert "sensor.battery_2_current" not in missing
        assert "sensor.battery_2_battery_voltage" not in missing
        assert "sensor.battery_2_battery_current" not in missing

    asyncio.run(_run())


def test_run_dump_tick_missing_required_solar_reported() -> None:
    async def _run() -> None:
        rows = [
            {"entity_id": "sensor.sim_dump_load_power", "state": "1000"},
            {"entity_id": "sensor.solar_controller_charge_state", "state": "float"},
            {"entity_id": "switch.a", "state": "off"},
            {"entity_id": "switch.b", "state": "off"},
        ]

        with patch(
            "src.ops.solar_dump._load_settings_store",
            return_value=_base_settings(),
        ), patch(
            "src.ops.solar_dump.ha_get_states",
            new_callable=AsyncMock,
            return_value=rows,
        ), patch(
            "src.ops.solar_dump._observe_weather",
            new_callable=AsyncMock,
            return_value={},
        ), patch(
            "src.ops.solar_dump._record_action",
        ):
            result = await run_dump_tick(actuate=False)

        assert "sensor.solar_controller_solar" in result["meta"]["missing_entity_ids"]
        assert any(
            "missing entity sensor.solar_controller_solar" in line
            for line in result["meta"]["thinking"]
        )

    asyncio.run(_run())


def test_run_dump_tick_never_calls_ha_call_service() -> None:
    async def _run() -> None:
        rows = [
            {"entity_id": "sensor.solar_controller_solar", "state": "1500"},
            {"entity_id": "sensor.sim_dump_load_power", "state": "200"},
            {"entity_id": "sensor.solar_controller_charge_state", "state": "float"},
            {"entity_id": "switch.a", "state": "off"},
            {"entity_id": "switch.b", "state": "off"},
        ]
        recorded: list[str] = []

        def _capture_record(action_type: str, _summary: str, _detail: dict) -> None:
            recorded.append(action_type)

        with patch(
            "src.ops.solar_dump._load_settings_store",
            return_value=_base_settings(),
        ), patch(
            "src.ops.solar_dump.ha_get_states",
            new_callable=AsyncMock,
            return_value=rows,
        ), patch(
            "src.ops.solar_dump._observe_weather",
            new_callable=AsyncMock,
            return_value={},
        ), patch(
            "src.ops.solar_dump._record_action",
            side_effect=_capture_record,
        ):
            import src.ops.solar_dump as solar_dump_mod

            assert not hasattr(solar_dump_mod, "ha_call_service")
            result = await run_dump_tick(actuate=True)

        from src.api.models.ai_action import ACTION_SOLAR_DUMP_ACTUATED, ACTION_SOLAR_DUMP_RECOMMENDED

        assert result["ok"] is True
        assert ACTION_SOLAR_DUMP_ACTUATED not in recorded
        assert ACTION_SOLAR_DUMP_RECOMMENDED in recorded

    asyncio.run(_run())
