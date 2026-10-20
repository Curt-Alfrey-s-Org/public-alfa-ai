"""Tests for chat model alias blocklist and Phase H picker defaults (27B)."""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _clear_model_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DEFAULT_MODEL", raising=False)
    monkeypatch.delenv("CHAT_MODELS", raising=False)
    monkeypatch.delenv("GUEST_CHAT_MODEL", raising=False)
    monkeypatch.delenv("OPERATOR_CHAT_MODEL", raising=False)
    monkeypatch.delenv("ALFA_INFERENCE_MODE", raising=False)
    monkeypatch.delenv("ALFA_inference_FAMILY", raising=False)


def test_retired_alias_sanitized_to_production_default() -> None:
    from src.api.llm_config import sanitize_chat_model_alias

    assert sanitize_chat_model_alias("qwen3.5:27b") == "frontier-code"
    assert sanitize_chat_model_alias("qwen3.6:35b-a3b") == "frontier-code"
    assert sanitize_chat_model_alias("qwen3:32b") == "frontier-code"
    assert sanitize_chat_model_alias("") == "frontier-code"
    assert sanitize_chat_model_alias(None) == "frontier-code"


def test_retired_default_model_env_still_maps_to_phase_h(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.llm_config import default_model_name

    monkeypatch.setenv("DEFAULT_MODEL", "qwen3.6:35b-a3b")
    assert default_model_name() == "frontier-code"


def test_chat_model_aliases_exclude_retired_from_env(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.llm_config import chat_model_aliases

    monkeypatch.setenv(
        "CHAT_MODELS",
        "qwen3.6:35b-a3b,fast,chat,frontier",
    )
    assert chat_model_aliases() == ["fast", "chat", "frontier"]


def test_default_picker_aliases_phase_h() -> None:
    from src.api.llm_config import chat_model_aliases

    aliases = chat_model_aliases()
    assert aliases == ["frontier-code", "frontier", "fast", "chat"]
    assert "qwen3.6:35b-a3b" not in aliases
    assert "qwen3.5:27b" not in aliases


def test_chat_models_for_ui_ignores_env_pipe_labels(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.llm_config import chat_models_for_ui

    monkeypatch.setenv(
        "CHAT_MODELS",
        "frontier|Frontier - largest reasoning model,"
        "frontier-code|Frontier code - complex coding tasks",
    )
    rows = {row["id"]: row["label"] for row in chat_models_for_ui()}
    assert rows["frontier"] == "Frontier - Qwen3.8 27B"
    assert rows["frontier-code"] == "Frontier code - Qwen3.8 27B"


def test_chat_models_for_ui_qwen36_family_labels(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.llm_config import chat_models_for_ui

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "inference")
    monkeypatch.setenv("ALFA_inference_FAMILY", "qwen36")
    monkeypatch.setenv("CHAT_MODELS", "frontier-code,qwen3.6-27b")
    rows = {row["id"]: row["label"] for row in chat_models_for_ui()}
    assert rows["frontier-code"] == "Frontier code - Qwen3.6 27B"
    assert rows["qwen3.6-27b"] == "Code - Qwen3.6 27B"


def test_chat_models_for_ui_unknown_family_falls_back_to_38(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.llm_config import chat_models_for_ui

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "inference")
    monkeypatch.setenv("ALFA_inference_FAMILY", "not-a-family")
    monkeypatch.setenv("CHAT_MODELS", "frontier-code")
    rows = {row["id"]: row["label"] for row in chat_models_for_ui()}
    assert rows["frontier-code"] == "Frontier code - Qwen3.8 27B"


def test_inference_family_display_default_qwen38(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.llm_config import inference_family_display

    assert inference_family_display() == "Qwen3.8 27B"


def test_chat_models_for_ui_labels_are_user_safe() -> None:
    from src.api.llm_config import chat_models_for_ui

    rows = {row["id"]: row["label"] for row in chat_models_for_ui()}
    assert "Qwen3.8 27B" in rows["fast"]
    assert "Qwen3.8 27B" in rows["chat"]
    assert "Qwen3.8 27B" in rows["frontier"]
    assert "Qwen3.8 27B" in rows["frontier-code"]
    assert "35B" not in rows["fast"]
    assert "orchestrator" not in rows["fast"]
    assert "llama.cpp" not in rows.get("frontier", "").lower()
    assert "Petals" not in rows.get("frontier", "")


def test_chat_models_for_ui_includes_active_flag(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api import inference_shards as p27
    from src.api import worker_monitoring as wm
    from src.api.llm_config import chat_models_for_ui

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "inference")
    monkeypatch.setattr(wm, "check_frontier_coordinator", lambda: {"ok": True})
    monkeypatch.setattr(p27, "check_inference_shards", lambda **kw: {"ok": True, "shards": []})

    by_id = {row["id"]: row for row in chat_models_for_ui()}
    assert by_id["frontier"]["active"] is True
    assert by_id["frontier-code"]["active"] is True
    assert by_id["fast"]["active"] is True


def test_chat_alias_is_active_speed_tier_uses_frontier(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api import inference_shards as p27
    from src.api import worker_monitoring as wm
    from src.api.llm_config import chat_alias_is_active

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "inference")
    monkeypatch.setattr(wm, "check_frontier_coordinator", lambda: {"ok": False})
    monkeypatch.setattr(p27, "check_inference_shards", lambda **kw: {"ok": True, "shards": []})

    assert chat_alias_is_active("fast") is False
    assert chat_alias_is_active("chat") is False


def test_inference_mode_only_frontier_code_active(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api import inference_shards as p27
    from src.api import worker_monitoring as wm
    from src.api.llm_config import chat_alias_is_active

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "inference")
    monkeypatch.setattr(wm, "check_frontier_coordinator", lambda: {"ok": True})
    monkeypatch.setattr(p27, "check_inference_shards", lambda **kw: {"ok": True, "shards": []})

    assert chat_alias_is_active("frontier-code") is True
    assert chat_alias_is_active("frontier") is True
    assert chat_alias_is_active("qwen3.6-27b") is True
    assert chat_alias_is_active("fast") is True


def test_inference_mode_frontier_code_inactive_when_coordinator_down(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Picker uses coordinator /health only (do not TCP-probe shards -- B42)."""
    from src.api import worker_monitoring as wm
    from src.api.llm_config import chat_alias_is_active

    monkeypatch.setenv("ALFA_INFERENCE_MODE", "inference")
    monkeypatch.setattr(wm, "check_frontier_coordinator", lambda: {"ok": False})

    assert chat_alias_is_active("frontier-code") is False


def test_chat_model_aliases_inference_env(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.llm_config import chat_model_aliases

    monkeypatch.setenv("CHAT_MODELS", "frontier-code,qwen3.6-27b")
    assert chat_model_aliases() == ["frontier-code", "qwen3.6-27b"]


def test_llm_tuple_sanitizes_retired_override(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.api.llm_config import llm_tuple

    _, _, model, _ = llm_tuple(role="chat", model_override="qwen3.6:35b-a3b")
    assert model == "frontier-code"
