"""ha_switch_watts ai_settings validation."""

from __future__ import annotations

import pytest

from src.api.models.ai_setting import AiSettingError, validate_setting_value


def test_ha_switch_watts_validates_pairs() -> None:
    raw = "switch.sim_ac_plug_1=180,switch.sim_ac_plug_2=300"
    assert validate_setting_value("ha_switch_watts", raw) == raw


def test_ha_switch_watts_rejects_bad_pair() -> None:
    with pytest.raises(AiSettingError, match="entity_id=watts"):
        validate_setting_value("ha_switch_watts", "switch.bad")


def test_ha_switch_watts_rejects_out_of_range() -> None:
    with pytest.raises(AiSettingError, match="between 0 and 100000"):
        validate_setting_value("ha_switch_watts", "switch.a=100001")
