"""Ask ALFa native OpenAI tools (ALFA_AI_NATIVE_TOOLS=1) with JSON-in-text fallback."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock

import pytest

from src.agent.openai_tools import ask_alfa_openai_tools_payload
from src.api.models.user import UserRecord
from src.api.routers import admin as admin_module
from src.config import native_tools_enabled
from src.llm.client import ChatTurn, NativeToolCall
from src.ops.exec_result import ExecResult


def _fake_user() -> UserRecord:
    return UserRecord(
        id="admin-1",
        email="operator@example.com",
        username="admin",
        password_hash="x",
        role="admin",
        is_active=True,
    )


def _fake_settings(inspect_on: bool = True) -> MagicMock:
    settings = MagicMock()
    settings.get_bool.return_value = inspect_on
    settings.all.return_value = []
    return settings


def _common_inspect_mocks(monkeypatch: pytest.MonkeyPatch) -> None:
    fake_result = ExecResult(
        ok=True,
        command_run="docker ps",
        stdout="x",
        stderr="",
        exit_code=0,
    )
    monkeypatch.setattr(
        admin_module,
        "run_inspect_action_sync",
        lambda *a, **k: fake_result,
    )
    monkeypatch.setattr(
        admin_module,
        "validate_proposal",
        lambda action_key, host, params, config, enforce_enabled=True: (
            MagicMock(),
            {"repo_dir": "/tmp"},
            dict(params or {}),
        ),
    )
    monkeypatch.setattr(
        admin_module,
        "_host_actions_readiness",
        lambda: {
            "env_enabled": True,
            "ssh_key_present": True,
            "ready": True,
            "missions_ready": True,
            "ssh_key_path": "/app/secrets/host-actions/id_ed25519",
        },
    )
    monkeypatch.setattr(admin_module, "host_actions_enabled", lambda: True)


def test_ask_alfa_openai_tools_payload_has_inspect_and_propose() -> None:
    names = {item["function"]["name"] for item in ask_alfa_openai_tools_payload()}
    assert names == {"inspect_host", "propose_host_action"}


def test_native_tools_enabled_default_off(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ALFA_AI_NATIVE_TOOLS", raising=False)
    assert native_tools_enabled() is False


def test_native_tools_inspect_via_tool_calls(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Native inspect_host tool_calls execute without JSON-in-text fallback."""
    monkeypatch.setenv("ALFA_AI_NATIVE_TOOLS", "1")
    _common_inspect_mocks(monkeypatch)

    turns = [
        ChatTurn(
            content="",
            tool_calls=[
                NativeToolCall(
                    id="call_inspect",
                    name="inspect_host",
                    arguments={
                        "action_key": "docker_ps",
                        "host": "106",
                        "params": {},
                    },
                )
            ],
        ),
        ChatTurn(
            content='{"reply":"Found containers.","setting_change":null,"host_action_id":null}',
            tool_calls=[],
        ),
    ]

    def fake_turn(messages: list, **kwargs: Any) -> ChatTurn:
        return turns.pop(0)

    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", fake_turn)

    actions = MagicMock()
    result = admin_module._monitoring_agent_llm_result(
        message="show containers on 106",
        user=_fake_user(),
        context={"ai_settings": []},
        config={},
        settings=_fake_settings(),
        actions=actions,
        host_store=MagicMock(),
    )

    assert len(result["inspections"]) == 1
    assert result["inspections"][0]["action_key"] == "docker_ps"
    actions.record.assert_called_once()
    assert actions.record.call_args[0][0] == "host_inspect_executed"


def test_native_tools_passes_tools_not_json_on_tool_turn(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ALFA_AI_NATIVE_TOOLS", "1")
    _common_inspect_mocks(monkeypatch)
    captured: list[dict[str, Any]] = []

    def fake_turn(messages: list, **kwargs: Any) -> ChatTurn:
        captured.append(dict(kwargs))
        if len(captured) == 1:
            return ChatTurn(
                content="",
                tool_calls=[
                    NativeToolCall(
                        id="call_1",
                        name="inspect_host",
                        arguments={
                            "action_key": "docker_ps",
                            "host": "106",
                            "params": {},
                        },
                    )
                ],
            )
        return ChatTurn(
            content='{"reply":"done","setting_change":null,"host_action_id":null}',
            tool_calls=[],
        )

    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", fake_turn)

    admin_module._monitoring_agent_llm_result(
        message="inspect",
        user=_fake_user(),
        context={"ai_settings": []},
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=MagicMock(),
    )

    assert captured
    first = captured[0]
    assert first.get("tools")
    assert len(first["tools"]) == 2
    assert first.get("response_format") is None


def test_json_in_text_still_works_when_native_off(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Default path: JSON-in-text inspect_host when ALFA_AI_NATIVE_TOOLS=0."""
    monkeypatch.delenv("ALFA_AI_NATIVE_TOOLS", raising=False)
    _common_inspect_mocks(monkeypatch)

    completions = [
        '{"tool":"inspect_host","args":{"action_key":"docker_ps","host":"106","params":{}}}',
        '{"reply":"ok","setting_change":null,"host_action_id":null}',
    ]

    def fake_turn(messages: list, **kwargs: Any) -> ChatTurn:
        return ChatTurn(content=completions.pop(0), tool_calls=[])

    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", fake_turn)

    result = admin_module._monitoring_agent_llm_result(
        message="inspect",
        user=_fake_user(),
        context={"ai_settings": []},
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=MagicMock(),
    )

    assert len(result["inspections"]) == 1
    assert result["inspections"][0]["action_key"] == "docker_ps"


@dataclass
class _FakeHostRecord:
    id: str
    summary: str


def test_native_tools_json_in_text_fallback_inspect(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Native on: empty tool_calls still parses JSON-in-text inspect_host."""
    monkeypatch.setenv("ALFA_AI_NATIVE_TOOLS", "1")
    _common_inspect_mocks(monkeypatch)
    captured: list[dict[str, Any]] = []

    completions = [
        '{"tool":"inspect_host","args":{"action_key":"docker_ps","host":"106","params":{}}}',
        '{"reply":"ok","setting_change":null,"host_action_id":null}',
    ]

    def fake_turn(messages: list, **kwargs: Any) -> ChatTurn:
        captured.append(dict(kwargs))
        return ChatTurn(content=completions.pop(0), tool_calls=[])

    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", fake_turn)

    result = admin_module._monitoring_agent_llm_result(
        message="inspect containers on 106",
        user=_fake_user(),
        context={"ai_settings": []},
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=MagicMock(),
    )

    assert len(result["inspections"]) == 1
    assert result["inspections"][0]["action_key"] == "docker_ps"
    assert captured
    first = captured[0]
    assert first.get("tools")
    assert len(first["tools"]) == 2
    assert first.get("response_format") is None


def test_native_tools_propose_host_action_stays_pending(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Native propose_host_action queues pending; does not execute mutate."""
    monkeypatch.setenv("ALFA_AI_NATIVE_TOOLS", "1")
    monkeypatch.setenv("ALFA_AI_HOST_ACTIONS_ENABLED", "1")

    host_store = MagicMock()
    host_store.create_pending.return_value = _FakeHostRecord(
        id="act-pending-1",
        summary="run_command on host 106",
    )

    inspect_called = False

    def fake_run_inspect(*_a: Any, **_k: Any) -> ExecResult:
        nonlocal inspect_called
        inspect_called = True
        return ExecResult(
            ok=True,
            command_run="",
            stdout="",
            stderr="",
            exit_code=0,
        )

    monkeypatch.setattr(admin_module, "run_inspect_action_sync", fake_run_inspect)
    monkeypatch.setattr(admin_module, "host_actions_enabled", lambda: True)
    monkeypatch.setattr(
        admin_module,
        "validate_proposal",
        lambda action_key, host, params, config, enforce_enabled=True: (
            MagicMock(),
            {"repo_dir": "/tmp"},
            dict(params or {}),
        ),
    )

    turns = [
        ChatTurn(
            content="",
            tool_calls=[
                NativeToolCall(
                    id="call_propose",
                    name="propose_host_action",
                    arguments={
                        "action_key": "run_command",
                        "host": "106",
                        "params": {"command": "echo test"},
                    },
                )
            ],
        ),
        ChatTurn(
            content='{"reply":"Proposed restart.","setting_change":null,"host_action_id":null}',
            tool_calls=[],
        ),
    ]

    def fake_turn(messages: list, **kwargs: Any) -> ChatTurn:
        return turns.pop(0)

    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", fake_turn)

    result = admin_module._monitoring_agent_llm_result(
        message="restart service on 106",
        user=_fake_user(),
        context={"ai_settings": []},
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=host_store,
    )

    host_store.create_pending.assert_called_once()
    call = host_store.create_pending.call_args
    assert call[0][0] == "run_command"
    assert call[0][1] == "106"
    assert call[1]["proposed_by"] == "ai"
    assert result["host_action_proposal"] is not None
    assert result["host_action_proposal"]["id"] == "act-pending-1"
    assert result["host_action_proposal"]["status"] == "pending"
    assert result["host_action_proposal"]["action_key"] == "run_command"
    assert not inspect_called
