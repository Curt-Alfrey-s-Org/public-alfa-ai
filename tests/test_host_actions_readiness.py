"""Host-actions readiness: SSH key is not required for Missions enqueue."""

from __future__ import annotations

import pytest

from src.api.routers.admin import _MONITORING_AGENT_SYSTEM, _host_actions_readiness


def test_missions_ready_without_ssh_key(
    monkeypatch: pytest.MonkeyPatch, tmp_path
) -> None:
    monkeypatch.setenv("ALFA_AI_HOST_ACTIONS_ENABLED", "1")
    monkeypatch.setenv("ALFA_AI_HOST_ACTIONS_SSH_KEY", str(tmp_path / "no-such-key"))
    readiness = _host_actions_readiness()
    assert readiness["env_enabled"] is True
    assert readiness["ssh_key_present"] is False
    assert readiness["ready"] is False
    assert readiness["missions_ready"] is True


def test_ask_alfa_prompt_allows_enqueue_without_ssh() -> None:
    text = _MONITORING_AGENT_SYSTEM
    assert "missions_ready" in text
    assert "readiness.ready is false" in text
    assert "internal brain API" in text
    assert "inspect_host" in text
    assert "Do not invent job counts from sample sizes" in text
    assert "no frontier-code call" in text


def test_ask_alfa_prompt_dump_independent_of_7b_27b() -> None:
    text = _MONITORING_AGENT_SYSTEM
    assert "Dump does not require 7B or 27B" in text
    assert "do not pick a model size to dump" in text
    assert "standing night loads" in text
    assert "sensor.battery_1_power" in text
    assert "sensor.sungold_sph302480a_load_power" in text
    assert "Do not ask the operator to type the wattage" in text
    assert "sensor.sim_ac_plug_N_power" in text
    assert "Write AC-cap / inverter" in text
    assert "400 W" not in text
