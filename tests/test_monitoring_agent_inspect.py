"""Unit tests for Ask ALFa inspect_host tool loop and readiness blocks."""

from __future__ import annotations

import json
from typing import Any
from unittest.mock import MagicMock

import pytest

from src.api.models.user import UserRecord
from src.api.routers import admin as admin_module
from src.llm.client import ChatTurn
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


def test_inspect_host_tool_records_step_and_progress(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    completions = [
        '{"tool":"inspect_host","args":{"action_key":"docker_ps","host":"106","params":{}}}',
        '{"reply":"Found 13 containers.","setting_change":null,"host_action_id":null}',
    ]

    def fake_completion(messages: list, **kwargs: Any) -> ChatTurn:
        return ChatTurn(content=completions.pop(0), tool_calls=[])

    fake_result = ExecResult(
        ok=True,
        command_run="docker ps",
        stdout="x",
        stderr="",
        exit_code=0,
    )
    progress_steps: list[dict[str, Any]] = []

    monkeypatch.setattr(
        "src.llm.client.get_agent_completion_turn",
        fake_completion,
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

    actions = MagicMock()
    host_store = MagicMock()

    result = admin_module._monitoring_agent_llm_result(
        message="show containers on 106",
        user=_fake_user(),
        context={"ai_settings": []},
        config={},
        settings=_fake_settings(),
        actions=actions,
        host_store=host_store,
        progress=progress_steps.append,
    )

    assert len(result["inspections"]) == 1
    assert result["inspections"][0]["action_key"] == "docker_ps"
    assert result["host_action_proposal"] is None
    actions.record.assert_called_once()
    assert actions.record.call_args[0][0] == "host_inspect_executed"
    assert len(progress_steps) == 1


def test_inspect_host_not_ready_skips_executor(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    called = False

    def fake_run(*a: Any, **k: Any) -> ExecResult:
        nonlocal called
        called = True
        return ExecResult(ok=True, command_run="", stdout="", stderr="", exit_code=0)

    monkeypatch.setattr(admin_module, "run_inspect_action_sync", fake_run)
    monkeypatch.setattr(
        admin_module,
        "_host_actions_readiness",
        lambda: {
            "env_enabled": True,
            "ssh_key_present": False,
            "ready": False,
            "ssh_key_path": "/app/secrets/host-actions/id_ed25519",
        },
    )

    out = admin_module._inspect_host_from_agent(
        {"action_key": "docker_ps", "host": "106", "params": {}},
        user=_fake_user(),
        actions=MagicMock(),
        settings=_fake_settings(),
        config={},
        budget_state={"start_time": 0, "inspections": [], "inspect_count": 0},
    )

    assert out["ok"] is False
    assert "SSH key" in out["error"]
    assert called is False


def test_inspect_budget_limits_executions(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    exec_count = 0
    tool_contents: list[str] = []

    def fake_run(*a: Any, **k: Any) -> ExecResult:
        nonlocal exec_count
        exec_count += 1
        return ExecResult(
            ok=True,
            command_run="docker ps",
            stdout="ok",
            stderr="",
            exit_code=0,
        )

    completions = [
        '{"tool":"inspect_host","args":{"action_key":"docker_ps","host":"106","params":{}}}',
    ] * 7 + [
        '{"reply":"done","setting_change":null,"host_action_id":null}',
    ]

    def fake_completion(messages: list, **kwargs: Any) -> ChatTurn:
        for msg in reversed(messages):
            if msg.get("role") == "tool":
                tool_contents.append(msg.get("content") or "")
                break
        return ChatTurn(content=completions.pop(0), tool_calls=[])

    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", fake_completion)
    monkeypatch.setattr(admin_module, "run_inspect_action_sync", fake_run)
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

    result = admin_module._monitoring_agent_llm_result(
        message="inspect",
        user=_fake_user(),
        context={"ai_settings": []},
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=MagicMock(),
    )

    assert exec_count == 6
    assert len(result["inspections"]) == 6
    assert len(tool_contents) == 7
    assert "budget" in tool_contents[-1]


def test_pre_inspections_do_not_consume_llm_inspect_budget(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Deterministic pre_inspect is shown in findings but does not use the 6 inspect_host calls."""
    exec_count = 0

    def fake_run(*a: Any, **k: Any) -> ExecResult:
        nonlocal exec_count
        exec_count += 1
        return ExecResult(ok=True, command_run="docker ps", stdout="ok", stderr="", exit_code=0)

    completions = [
        '{"tool":"inspect_host","args":{"action_key":"docker_ps","host":"106","params":{}}}',
    ] * 5 + [
        '{"reply":"done","setting_change":null,"host_action_id":null}',
    ]
    monkeypatch.setattr(
        "src.llm.client.get_agent_completion_turn",
        lambda messages, **kw: ChatTurn(content=completions.pop(0), tool_calls=[]),
    )
    monkeypatch.setattr(admin_module, "run_inspect_action_sync", fake_run)
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

    pre = [
        {
            "action_key": key,
            "host": "106",
            "command_run": "x",
            "stdout": "",
            "stderr": "",
            "exit_code": 0,
            "ok": True,
            "duration_ms": 1,
        }
        for key in ("repo_tree", "git_status", "docker_ps")
    ]
    result = admin_module._monitoring_agent_llm_result(
        message="inspect",
        user=_fake_user(),
        context={"ai_settings": []},
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=MagicMock(),
        pre_inspections=pre,
    )

    # 3 pre-inspections stay in the list; all 5 LLM inspect_host calls still run.
    assert exec_count == 5
    assert len(result["inspections"]) == 8


def test_inspect_findings_not_sliced_by_truncated_admin_context(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Huge catalog JSON must not hide inspect stdout from the first LLM turn."""
    captured: list[list[dict[str, str]]] = []

    def fake_completion(messages: list, **kwargs: Any) -> ChatTurn:
        captured.append(list(messages))
        return ChatTurn(
            content='{"reply":"Rankings scrapers are env flags.","setting_change":null,"host_action_id":null}',
            tool_calls=[],
        )

    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", fake_completion)
    huge = {
        "host_action_catalog": [{"key": "noise", "description": "x" * 400}] * 80,
        "ai_settings": [],
    }
    pre = [
        {
            "action_key": "repo_tree",
            "host": "106",
            "command_run": "git ls-files",
            "stdout": "UNIQUE_TREE_MARKER/scrapers/fargo.py\n",
            "stderr": "",
            "exit_code": 0,
            "ok": True,
            "duration_ms": 12,
        }
    ]
    admin_module._monitoring_agent_llm_result(
        message="analyze rankings bot repo, activate all scrapers",
        user=_fake_user(),
        context=huge,
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=MagicMock(),
        pre_inspections=pre,
        repo_target={
            "alias": "rankings-bot",
            "host": "106",
            "repo_dir": "/home/operator/rankings-bot",
        },
    )
    assert captured
    blob = json.dumps(captured[0])
    assert "UNIQUE_TREE_MARKER/scrapers/fargo.py" in blob
    assert "Inspect findings" in blob
    assert "inspect_steps_remaining" in blob
    assert "activate all scrapers" in blob


def test_web_search_pre_inspect_skips_ssh_readiness(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ALFA_AI_WEB_SEARCH_ENABLED", "1")
    monkeypatch.setattr(
        admin_module,
        "_host_actions_readiness",
        lambda: {
            "env_enabled": False,
            "ssh_key_present": False,
            "ready": False,
            "missions_ready": True,
            "ssh_key_path": "/app/secrets/host-actions/id_ed25519",
        },
    )
    captured: dict[str, Any] = {}

    def fake_turn(**kwargs: Any) -> dict[str, Any]:
        captured.update(kwargs)
        return {"ok": True, "reply": "search results", "inspections": []}

    monkeypatch.setattr(admin_module, "_run_llm_continue_turn", fake_turn)
    out = admin_module._handle_llm_continue_deterministic(
        {
            "llm_continue": True,
            "repo_target": {"host": "111"},
            "pre_inspect": [
                {"action_key": "web_search", "params": {"query": "fastapi streaming"}},
            ],
        },
        message="research online fastapi",
        user=_fake_user(),
        context={},
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=MagicMock(),
    )
    assert captured
    assert out["reply"] == "search results"
    assert "Cannot inspect" not in out.get("reply", "")


def test_web_search_disabled_pre_inspect_blocks_no_mission(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("ALFA_AI_WEB_SEARCH_ENABLED", raising=False)
    out = admin_module._handle_llm_continue_deterministic(
        {
            "llm_continue": True,
            "repo_target": {"host": "111"},
            "pre_inspect": [
                {"action_key": "web_search", "params": {"query": "fastapi"}},
            ],
        },
        message="research online fastapi",
        user=_fake_user(),
        context={},
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=MagicMock(),
    )
    assert "web_search disabled" in out["reply"]
    assert "mission" not in out["reply"].lower() or "not queue a mission" in out["reply"].lower()
    assert out["host_action_proposal"] is None


def test_ha_weather_pre_inspect_skips_ssh_readiness(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(admin_module, "_home_assistant_ready", lambda: True)
    monkeypatch.setattr(
        admin_module,
        "_host_actions_readiness",
        lambda: {
            "env_enabled": False,
            "ssh_key_present": False,
            "ready": False,
            "missions_ready": True,
            "ssh_key_path": "/app/secrets/host-actions/id_ed25519",
        },
    )
    captured: dict[str, Any] = {}

    def fake_turn(**kwargs: Any) -> dict[str, Any]:
        captured.update(kwargs)
        return {"ok": True, "reply": "hourly forecast", "inspections": []}

    monkeypatch.setattr(admin_module, "_run_llm_continue_turn", fake_turn)
    out = admin_module._handle_llm_continue_deterministic(
        {
            "llm_continue": True,
            "repo_target": {"host": "105"},
            "pre_inspect": [
                {"action_key": "ha_get_forecasts", "params": {"type": "hourly"}},
                {"action_key": "ha_get_state", "params": {}},
            ],
        },
        message="weather",
        user=_fake_user(),
        context={},
        config={},
        settings=_fake_settings(),
        actions=MagicMock(),
        host_store=MagicMock(),
    )
    assert captured
    assert out["reply"] == "hourly forecast"
    assert "Cannot inspect" not in out.get("reply", "")


def test_readiness_block_result_shape() -> None:
    out = admin_module._readiness_block_result(
        "106",
        {
            "ready": False,
            "ssh_key_present": False,
            "ssh_key_path": "/app/secrets/host-actions/id_ed25519",
            "env_enabled": True,
        },
    )
    assert out["host_action_proposal"] is None
    assert out["readiness_block"]["fix_steps"]
    assert "Cannot inspect host 106" in out["reply"]
    assert out["inspections"] == []


def test_inspect_host_rejects_mutating_action(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    called = False

    def fake_run(*a: Any, **k: Any) -> ExecResult:
        nonlocal called
        called = True
        return ExecResult(ok=True, command_run="", stdout="", stderr="", exit_code=0)

    monkeypatch.setattr(admin_module, "run_inspect_action_sync", fake_run)
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

    out = admin_module._inspect_host_from_agent(
        {"action_key": "git_pull", "host": "106", "params": {}},
        user=_fake_user(),
        actions=MagicMock(),
        settings=_fake_settings(),
        config={},
        budget_state={"start_time": 0, "inspections": [], "inspect_count": 0},
    )

    assert out["ok"] is False
    assert "not a read-only inspect action" in out["error"]
    assert called is False
