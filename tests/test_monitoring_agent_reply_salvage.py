"""Ask ALFa reply envelope: salvage malformed JSON and never show raw blobs."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

MALFORMED_PRODUCTION_PAYLOAD = (
    '{ "reply": "The only other recent activity (CpuTemperatureHigh triage - "medium" '
    '- notification skipped) was at 21:52.", "setting_change": null, "host_action_id": null }'
)

WELL_FORMED_PAYLOAD = (
    '{"reply":"Cluster looks healthy overall.","setting_change":null,"host_action_id":null}'
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
        ],
        "host_action_catalog": [],
        "host_actions_readiness": {},
    }


def _mock_stores() -> tuple[MagicMock, MagicMock, MagicMock, MagicMock]:
    host_store = MagicMock()
    host_store.list_actions.return_value = []
    host_store.get_by_id.return_value = None

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


def test_malformed_reply_envelope_renders_as_prose(
    monitoring_agent_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.llm.client import ChatTurn

    llm_mock = MagicMock(return_value=ChatTurn(content=MALFORMED_PRODUCTION_PAYLOAD))
    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", llm_mock)

    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={"message": "What happened recently?"},
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    body = resp.json()
    reply = body["reply"]
    assert "The only other recent activity" in reply
    assert "medium" in reply
    assert "setting_change" not in reply
    assert not reply.lstrip().startswith("{")


def test_well_formed_reply_envelope_still_parses(
    monitoring_agent_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.llm.client import ChatTurn

    llm_mock = MagicMock(return_value=ChatTurn(content=WELL_FORMED_PAYLOAD))
    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", llm_mock)

    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={"message": "How is the cluster?"},
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["reply"] == "Cluster looks healthy overall."


def test_salvage_reply_unit() -> None:
    from src.api.routers.admin import _parse_monitoring_agent_reply

    reply, parsed = _parse_monitoring_agent_reply(MALFORMED_PRODUCTION_PAYLOAD)
    assert "CpuTemperatureHigh triage" in reply
    assert "medium" in reply
    assert "setting_change" not in reply
    assert not reply.startswith("{")
    assert parsed is not None
    assert parsed.get("setting_change") is None


def test_salvage_tolerates_pretty_printed_envelope() -> None:
    """Newlines around the comma must not let a following key leak into the prose."""
    from src.api.routers.admin import _parse_monitoring_agent_reply

    payload = (
        "{\n"
        '  "reply": "Triage came back as "medium" so nothing was sent.",\n'
        '  "setting_change": null,\n'
        '  "host_action_id": null\n'
        "}"
    )

    reply, _ = _parse_monitoring_agent_reply(payload)
    assert reply == 'Triage came back as "medium" so nothing was sent.'
    assert "setting_change" not in reply
    assert "host_action_id" not in reply


def test_salvage_restores_escaped_newlines() -> None:
    from src.api.routers.admin import _parse_monitoring_agent_reply

    payload = (
        '{ "reply": "Line one.\\n\\n1. First item was "medium" severity\\n2. Second item", '
        '"setting_change": null, "host_action_id": null }'
    )

    reply, _ = _parse_monitoring_agent_reply(payload)
    assert "\n\n1. First item" in reply
    assert "\\n" not in reply
    assert reply.endswith("2. Second item")


def test_unsalvageable_envelope_never_shows_raw_json() -> None:
    from src.api.routers.admin import _parse_monitoring_agent_reply

    reply, parsed = _parse_monitoring_agent_reply('{"unexpected": "shape", "n": 1}')
    assert not reply.lstrip().startswith("{")
    assert "unexpected" not in reply
    assert parsed is None


def test_salvage_never_applies_a_setting_scraped_from_prose() -> None:
    """A malformed envelope must not yield structured fields.

    The reply text quotes a setting_change example while the real envelope value is
    null. Scraping the raw blob would apply notify_min_severity (not a policy key,
    so no Approve gate) purely because the model quoted it.
    """
    from src.api.routers.admin import _parse_monitoring_agent_reply

    payload = (
        '{ "reply": "Never write "setting_change": {"key": "notify_min_severity", '
        '"value": "low"} in your own examples.", "setting_change": null, '
        '"host_action_id": null }'
    )

    reply, parsed = _parse_monitoring_agent_reply(payload)
    assert "Never write" in reply
    assert "notify_min_severity" in reply
    assert parsed is not None
    assert parsed.get("setting_change") is None
    assert parsed.get("host_action_id") is None


def test_malformed_envelope_applies_no_setting_end_to_end(
    monitoring_agent_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload = (
        '{ "reply": "Example only: "setting_change": {"key": "notify_min_severity", '
        '"value": "low"}.", "setting_change": null, "host_action_id": null }'
    )
    from src.llm.client import ChatTurn

    monkeypatch.setattr(
        "src.llm.client.get_agent_completion_turn",
        MagicMock(return_value=ChatTurn(content=payload)),
    )

    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={"message": "How should I phrase setting changes?"},
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body.get("applied_setting") is None
    assert body.get("pending_setting_proposal") is None


def test_unclosed_reply_string_does_not_leak_envelope_keys() -> None:
    from src.api.routers.admin import _parse_monitoring_agent_reply

    payload = '{"reply": "hello world, "setting_change": null, "host_action_id": null}'

    reply, _ = _parse_monitoring_agent_reply(payload)
    assert "setting_change" not in reply
    assert "host_action_id" not in reply
    assert not reply.lstrip().startswith("{")


def test_router_sends_json_mode_on_first_turn(
    monitoring_agent_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Guards against a router regression that drops response_format."""
    from src.llm.client import ChatTurn

    monkeypatch.setenv("ALFA_AI_AGENT_JSON_MODE", "1")
    llm_mock = MagicMock(return_value=ChatTurn(content=WELL_FORMED_PAYLOAD))
    monkeypatch.setattr("src.llm.client.get_agent_completion_turn", llm_mock)

    resp = monitoring_agent_client.post(
        "/alfa-ai/api/admin/monitoring-agent",
        json={"message": "How is the cluster?"},
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    assert llm_mock.call_args.kwargs["response_format"] == {"type": "json_object"}


def test_plain_prose_reply_passes_through_unchanged() -> None:
    from src.api.routers.admin import _parse_monitoring_agent_reply

    reply, parsed = _parse_monitoring_agent_reply("Everything looks healthy right now.")
    assert reply == "Everything looks healthy right now."
    assert parsed is None
