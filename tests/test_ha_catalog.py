"""Home Assistant catalog validation tests."""

from __future__ import annotations

import pytest

from src.ops.host_catalog import (
    build_command,
    is_ha_auto_actuate,
    is_ha_inspect_action,
    is_inspectable,
    list_all_catalog_entries,
    summarize_proposal,
    validate_proposal,
)


def test_validate_proposal_ha_requires_host_105() -> None:
    with pytest.raises(ValueError, match="not allowed on host 111"):
        validate_proposal("ha_get_states", "111", {}, {}, enforce_enabled=False)


def test_validate_ha_switch_rejects_unknown_entity(monkeypatch) -> None:
    monkeypatch.setattr(
        "src.ops.solar_dump.load_ha_switch_allowlist",
        lambda settings=None: frozenset({"switch.allowed"}),
    )
    with pytest.raises(ValueError, match="not in ha_switch_allowlist"):
        validate_proposal(
            "ha_switch_on",
            "105",
            {"entity_id": "switch.other"},
            {},
            enforce_enabled=False,
        )


def test_validate_ha_switch_rejects_when_allowlist_empty_via_settings() -> None:
    with pytest.raises(ValueError, match="empty"):
        validate_proposal(
            "ha_switch_on",
            "105",
            {"entity_id": "switch.sim_ac_plug_1"},
            {},
            settings={"ha_switch_allowlist": ""},
            enforce_enabled=False,
        )


def test_validate_ha_switch_uses_settings_allowlist() -> None:
    _, _, norm = validate_proposal(
        "ha_switch_on",
        "105",
        {"entity_id": "switch.custom"},
        {},
        settings={"ha_switch_allowlist": "switch.custom"},
        enforce_enabled=False,
    )
    assert norm["entity_id"] == "switch.custom"


def test_build_command_ha_raises_internal_httpx() -> None:
    host = {"key": "105", "os_type": "linux"}
    with pytest.raises(ValueError, match="internal Home Assistant httpx"):
        build_command("ha_get_states", host, {}, {})


def test_is_inspectable_ha_read_actions() -> None:
    assert is_inspectable("ha_get_states") is True
    assert is_inspectable("ha_get_state") is True
    assert is_inspectable("ha_get_forecasts") is True
    assert is_inspectable("ha_dump_tick") is True
    assert is_ha_inspect_action("ha_dump_tick") is True
    assert is_ha_inspect_action("ha_get_states") is True
    assert is_ha_inspect_action("ha_switch_on") is False
    assert is_inspectable("ha_switch_on") is False


def test_is_ha_auto_actuate_mutate_actions() -> None:
    assert is_ha_auto_actuate("ha_switch_on") is True
    assert is_ha_auto_actuate("ha_switch_off") is True
    assert is_ha_auto_actuate("ha_dump_tick") is True
    assert is_ha_auto_actuate("ha_soak_tick") is True
    assert is_ha_auto_actuate("ha_get_states") is False
    assert is_ha_auto_actuate("ha_get_forecasts") is False
    assert is_ha_auto_actuate("ha_set_number") is True
    assert is_ha_auto_actuate("ha_select_option") is True
    assert is_ha_auto_actuate("run_command") is False
    assert is_inspectable("ha_set_number") is False


def test_validate_ha_set_number_allowlist() -> None:
    _, _, norm = validate_proposal(
        "ha_set_number",
        "105",
        {"entity_id": "input_number.dump_ac_limit_t2_w", "value": 2000},
        {},
        enforce_enabled=False,
    )
    assert norm["value"] == 2000.0
    _, _, float_norm = validate_proposal(
        "ha_set_number",
        "105",
        {"entity_id": "input_number.dump_float_t2_v", "value": 27.0},
        {},
        enforce_enabled=False,
    )
    assert float_norm["value"] == 27.0
    with pytest.raises(ValueError, match="allowlisted dump number helper"):
        validate_proposal(
            "ha_set_number",
            "105",
            {"entity_id": "input_number.bedroom_brightness", "value": 1},
            {},
            enforce_enabled=False,
        )


def test_validate_ha_select_option_allowlist() -> None:
    _, _, norm = validate_proposal(
        "ha_select_option",
        "105",
        {"entity_id": "input_select.dump_plug_1_inverter", "option": "T2"},
        {},
        enforce_enabled=False,
    )
    assert norm["option"] == "T2"
    with pytest.raises(ValueError, match="T2, KU, or Sungold"):
        validate_proposal(
            "ha_select_option",
            "105",
            {"entity_id": "input_select.dump_plug_1_inverter", "option": "grid"},
            {},
            enforce_enabled=False,
        )


def test_summarize_ha_switch_no_token(monkeypatch) -> None:
    monkeypatch.setattr(
        "src.ops.solar_dump.load_ha_switch_allowlist",
        lambda settings=None: frozenset({"switch.trailer_plug_a"}),
    )
    summary = summarize_proposal(
        "ha_switch_on",
        "105",
        {"entity_id": "switch.trailer_plug_a"},
        {},
    )
    assert "switch.trailer_plug_a" in summary
    assert "Bearer" not in summary
    assert "token" not in summary.lower()


def test_summarize_ha_dump_tick_says_no_llm() -> None:
    summary = summarize_proposal("ha_dump_tick", "105", {}, {})
    assert "deterministic" in summary.lower()
    assert "no LLM" in summary or "no llm" in summary.lower()
    assert "7B" in summary
    assert "27B" in summary
    assert "token" not in summary.lower()
    dump_entry = next(e for e in list_all_catalog_entries() if e["key"] == "ha_dump_tick")
    assert "No LLM" in dump_entry["description"]
    assert "7B" in dump_entry["description"]
    assert dump_entry["mutating"] is False
    assert dump_entry["risk_tier"] == 1


def test_ha_action_runs_when_host_actions_env_off(monkeypatch) -> None:
    import asyncio

    from src.ops.exec_result import ExecResult
    from src.ops.ssh_executor import execute_host_action

    monkeypatch.setenv("ALFA_AI_HOST_ACTIONS_ENABLED", "0")

    async def _fake_ha(_key, _params):
        return ExecResult(
            ok=True,
            command_run="GET /api/states (dump sensors + allowlist)",
            stdout="[]",
            stderr="",
            exit_code=0,
        )

    monkeypatch.setattr("src.ops.ha_executor.execute_internal_ha_action", _fake_ha)

    async def _run():
        return await execute_host_action("ha_get_states", {"key": "105"}, {}, {})

    result = asyncio.run(_run())
    assert result.ok is True
    assert result.exit_code == 0


def test_ha_switch_on_empty_params_does_not_call_ha(monkeypatch) -> None:
    import asyncio

    from src.ops.ha_executor import execute_internal_ha_action

    monkeypatch.setenv("ALFA_AI_HOME_ASSISTANT_ENABLED", "1")
    monkeypatch.setattr(
        "src.ops.ha_executor.home_assistant_token_present",
        lambda: True,
    )
    ha_called = False

    async def _block_ha(*_args, **_kwargs):
        nonlocal ha_called
        ha_called = True
        raise AssertionError("ha_call_service must not run without entity_id")

    monkeypatch.setattr("src.ops.ha_executor.ha_call_service", _block_ha)

    async def _run():
        return await execute_internal_ha_action("ha_switch_on", {})

    result = asyncio.run(_run())
    assert ha_called is False
    assert result.ok is False
    assert result.exit_code == 2
    assert "entity_id" in result.stderr


def test_ha_switch_off_empty_params_does_not_call_ha(monkeypatch) -> None:
    import asyncio

    from src.ops.ha_executor import execute_internal_ha_action

    monkeypatch.setenv("ALFA_AI_HOME_ASSISTANT_ENABLED", "1")
    monkeypatch.setattr(
        "src.ops.ha_executor.home_assistant_token_present",
        lambda: True,
    )
    ha_called = False

    async def _block_ha(*_args, **_kwargs):
        nonlocal ha_called
        ha_called = True
        raise AssertionError("ha_call_service must not run without entity_id")

    monkeypatch.setattr("src.ops.ha_executor.ha_call_service", _block_ha)

    async def _run():
        return await execute_internal_ha_action("ha_switch_off", {})

    result = asyncio.run(_run())
    assert ha_called is False
    assert result.ok is False
    assert result.exit_code == 2
    assert "entity_id" in result.stderr


def test_ha_switch_auto_actuate_without_host_actions_ssh(monkeypatch) -> None:
    import asyncio

    from src.ops.exec_result import ExecResult
    from src.ops.ssh_executor import execute_host_action

    monkeypatch.setenv("ALFA_AI_HOST_ACTIONS_ENABLED", "0")

    async def _fake_ha(_key, _params):
        return ExecResult(
            ok=True,
            command_run="POST /api/services/switch/turn_on entity=switch.sim_ac_plug_1",
            stdout="switch.sim_ac_plug_1 -> turn_on",
            stderr="",
            exit_code=0,
        )

    monkeypatch.setattr("src.ops.ha_executor.execute_internal_ha_action", _fake_ha)

    async def _run():
        return await execute_host_action(
            "ha_switch_on",
            {"key": "105"},
            {"entity_id": "switch.sim_ac_plug_1"},
            {},
        )

    result = asyncio.run(_run())
    assert result.ok is True
    assert "turn_on" in result.command_run


def test_validate_ha_get_forecasts_defaults_and_rejects_non_weather() -> None:
    _, _, norm = validate_proposal(
        "ha_get_forecasts",
        "105",
        {},
        {},
        enforce_enabled=False,
    )
    assert norm["entity_id"] == "weather.417373300314"
    assert norm["type"] == "daily"
    with pytest.raises(ValueError, match="weather"):
        validate_proposal(
            "ha_get_forecasts",
            "105",
            {"entity_id": "sensor.417373300314_temperature"},
            {},
            enforce_enabled=False,
        )


def test_summarize_ha_get_forecasts_no_token() -> None:
    summary = summarize_proposal(
        "ha_get_forecasts",
        "105",
        {"entity_id": "weather.417373300314", "type": "hourly"},
        {},
    )
    assert "weather.417373300314" in summary
    assert "hourly" in summary
    assert "no dump toggle" in summary
    assert "token" not in summary.lower()
