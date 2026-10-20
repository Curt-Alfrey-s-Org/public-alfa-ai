"""Hybrid-path eval: monitoring_agent must short-circuit before get_agent_completion.

When try_handle_deterministic returns a dict, POST /monitoring-agent must return
immediately without calling the agent model. Ambiguous messages fall through to LLM.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

STRUCTURED_NO_LLM_PROMPTS = (
    "Propose docker_ps on host 111. Read-only only.",
    "Propose run_command on host 148 to run: docker restart llamacpp-rpc-coordinator",
    "Set notify_min_severity to critical",
    (
        "Reply with exactly three lines:\n"
        "1) notify_min_severity=\n"
        "2) notify_dedup_minutes=\n"
        "3) host_actions_enabled="
    ),
)

AMBIGUOUS_CLUSTER_PROMPT = (
    "Should we raise notify_min_severity given current dump and load tradeoffs?"
)


@dataclass
class _FakeHostRecord:
    id: str
    summary: str
    status: str = "pending"
    action_key: str = "docker_ps"


def _sample_context() -> dict[str, Any]:
    return {
        "host_actions_enabled": True,
        "user_count": 2,
        "ai_settings": [
            {"key": "notify_min_severity", "value": "high", "editable_by_ai": True},
            {"key": "notify_dedup_minutes", "value": "30", "editable_by_ai": True},
        ],
        "host_action_catalog": [],
        "host_actions_readiness": {},
    }


def _mock_stores() -> tuple[MagicMock, MagicMock, MagicMock, MagicMock]:
    host_store = MagicMock()
    host_store.create_pending.return_value = _FakeHostRecord(
        id="act-hybrid-1",
        summary="docker_ps on host 111 [read-only]",
    )
    host_store.get_by_id.return_value = None
    host_store.list_actions.return_value = []

    settings_store = MagicMock()
    settings_store.get.return_value = "high"
    settings_store.all.return_value = []

    actions_store = MagicMock()
    actions_store.list_actions.return_value = []

    agent_config_store = MagicMock()
    agent_config_store.get.return_value = {
        "context_sections": {},
        "disabled_actions": [],
    }
    return host_store, settings_store, actions_store, agent_config_store


@pytest.fixture
def monitoring_agent_client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("ALFA_AI_JWT_SECRET", "change-me")
    monkeypatch.setenv("ALFA_AI_HOST_ACTIONS_ENABLED", "1")
    monkeypatch.delenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", raising=False)

    from src.api.app import app
    from src.api.deps import (
        get_agent_config_store,
        get_ai_action_store,
        get_ai_setting_store,
        get_current_user,
        get_host_action_store,
        get_incident_store,
        get_security_store,
        get_user_store,
    )
    from src.api.models.user import UserRecord
    from src.api.routers import admin as admin_module

    admin = UserRecord(
        id="admin-1",
        email="operator@example.com",
        username="admin",
        password_hash="x",
        role="admin",
        is_2fa_enabled=False,
        is_active=True,
        totp_secret=None,
        created_at="2026-01-01T00:00:00Z",
    )

    host_store, settings_store, actions_store, agent_config_store = _mock_stores()

    async def _fake_gather_context(**kwargs: Any) -> dict[str, Any]:
        return _sample_context()

    monkeypatch.setattr(
        admin_module,
        "_gather_monitoring_agent_context",
        _fake_gather_context,
    )

    app.dependency_overrides[get_current_user] = lambda: admin
    app.dependency_overrides[get_incident_store] = lambda: MagicMock()
    app.dependency_overrides[get_ai_setting_store] = lambda: settings_store
    app.dependency_overrides[get_ai_action_store] = lambda: actions_store
    app.dependency_overrides[get_user_store] = lambda: MagicMock()
    app.dependency_overrides[get_security_store] = lambda: MagicMock()
    app.dependency_overrides[get_host_action_store] = lambda: host_store
    app.dependency_overrides[get_agent_config_store] = lambda: agent_config_store

    client = TestClient(app)
    yield client
    app.dependency_overrides.clear()


@pytest.mark.parametrize("message", STRUCTURED_NO_LLM_PROMPTS)
def test_monitoring_agent_structured_short_circuits_without_llm(
    monitoring_agent_client: TestClient,
    message: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("CTX_SIZE", raising=False)
    monkeypatch.delenv("LLAMA_ARG_CTX_SIZE", raising=False)
    monkeypatch.delenv("PARALLEL", raising=False)
    monkeypatch.delenv("LLAMA_ARG_N_PARALLEL", raising=False)
    llm_mock = MagicMock(
        side_effect=AssertionError("get_agent_completion must not run on structured intent")
    )
    monkeypatch.setattr("src.llm.client.get_agent_completion", llm_mock)

    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={"message": message},
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body.get("reply")
    usage = body.get("context_usage")
    assert usage is not None
    assert usage["window_tokens"] == 52428
    assert usage["source"] == "char_estimate"
    assert sum(c["tokens"] for c in usage["categories"]) == usage["used_tokens"]
    llm_mock.assert_not_called()


def test_monitoring_agent_ambiguous_calls_get_agent_completion(
    monitoring_agent_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.llm.client import ChatTurn

    llm_mock = MagicMock(
        return_value=ChatTurn(content='{"reply":"Checking cluster health and incidents."}')
    )
    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", llm_mock)

    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={"message": AMBIGUOUS_CLUSTER_PROMPT},
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body.get("context_usage") is not None
    llm_mock.assert_called_once()


def test_monitoring_agent_cluster_status_short_circuits_without_llm(
    monitoring_agent_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    llm_mock = MagicMock(
        side_effect=AssertionError("get_agent_completion must not run on cluster status")
    )
    monkeypatch.setattr("src.llm.client.get_agent_completion", llm_mock)
    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", llm_mock)

    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={"message": "What is wrong with the cluster?"},
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert "no frontier-code call" in body["reply"]
    assert body.get("host_action_proposal") is None
    llm_mock.assert_not_called()


def test_monitoring_agent_llm_setting_validation_appends_to_reply(
    monitoring_agent_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.llm.client import ChatTurn

    llm_mock = MagicMock(
        return_value=ChatTurn(
            content=(
                '{"reply":"Here is a detailed explanation of dedup settings.", '
                '"setting_change":{"key":"notify_dedup_minutes","value":"abc"}}'
            )
        )
    )
    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", llm_mock)

    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={"message": "Please adjust dedup and explain how it works."},
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert "detailed explanation" in body["reply"]
    assert "Setting change not applied" in body["reply"]
    assert "notify_dedup_minutes" in body["reply"]
    assert body.get("applied_setting") is None
    assert body.get("pending_setting_proposal") is None
    llm_mock.assert_called_once()


def test_monitoring_agent_history_in_packed_llm_messages(
    monitoring_agent_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.llm.client import ChatTurn

    captured_messages: list[dict[str, Any]] = []

    def fake_turn(messages: list[dict[str, Any]], **kw: Any) -> ChatTurn:
        captured_messages.extend(messages)
        return ChatTurn(content='{"reply":"Acknowledged prior context."}')

    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", fake_turn)

    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={
            "message": "yes, show me that",
            "history": [
                {"role": "user", "content": "what is degraded?"},
                {"role": "assistant", "content": "LiteLLM on 111 is down."},
            ],
        },
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    assert resp.json()["ok"] is True
    contents = [m.get("content", "") for m in captured_messages]
    assert "what is degraded?" in contents
    assert "LiteLLM on 111 is down." in contents
    op_idx = next(i for i, c in enumerate(contents) if c.startswith("Operator message:"))
    hist_user_idx = contents.index("what is degraded?")
    hist_asst_idx = contents.index("LiteLLM on 111 is down.")
    assert hist_user_idx < hist_asst_idx < op_idx


def test_monitoring_agent_rejects_more_than_eight_history_turns(
    monitoring_agent_client: TestClient,
) -> None:
    history = [
        {"role": "user", "content": f"turn {i}"} for i in range(9)
    ]
    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={"message": "hi", "history": history},
        headers={"Authorization": "Bearer fake"},
    )
    assert resp.status_code == 422


def test_ask_alfa_context_usage_get_no_llm(
    monitoring_agent_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("CTX_SIZE", raising=False)
    monkeypatch.delenv("LLAMA_ARG_CTX_SIZE", raising=False)
    monkeypatch.delenv("PARALLEL", raising=False)
    monkeypatch.delenv("LLAMA_ARG_N_PARALLEL", raising=False)
    llm_mock = MagicMock(
        side_effect=AssertionError("context-usage GET must not call get_agent_completion")
    )
    monkeypatch.setattr("src.llm.client.get_agent_completion", llm_mock)
    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", llm_mock)

    resp = monitoring_agent_client.get(
        "/alfa-ai/api/admin/ask-alfa/context-usage",
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    usage = body["context_usage"]
    assert usage["window_tokens"] == 52428
    assert usage["source"] == "char_estimate"
    assert usage["used_tokens"] > 0
    llm_mock.assert_not_called()
