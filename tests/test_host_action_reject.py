"""Host-action reject dual-write (NIST W1.4 / PR-03)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from src.api.models.ai_action import (
    ACTION_HOST_ACTION_REJECTED,
    category_for_action,
)


@dataclass
class _FakeHostRecord:
    id: str
    action_key: str
    host: str
    params: dict[str, Any]
    summary: str
    status: str = "rejected"
    command_run: str | None = None
    stdout: str | None = None
    stderr: str | None = None
    exit_code: int | None = None
    proposed_by: str = "ai"
    reviewed_by: str | None = "operator@example.com"
    created_at: str = "2026-01-01T00:00:00Z"
    executed_at: str | None = None


@pytest.fixture
def reject_client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("ALFA_AI_JWT_SECRET", "change-me")
    monkeypatch.delenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", raising=False)

    from src.api.app import app
    from src.api.deps import (
        get_ai_action_store,
        get_current_user,
        get_host_action_store,
        get_security_store,
    )
    from src.api.models.user import UserRecord

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

    host_store = MagicMock()
    actions_store = MagicMock()
    sec_store = MagicMock()

    app.dependency_overrides[get_current_user] = lambda: admin
    app.dependency_overrides[get_host_action_store] = lambda: host_store
    app.dependency_overrides[get_ai_action_store] = lambda: actions_store
    app.dependency_overrides[get_security_store] = lambda: sec_store

    client = TestClient(app)
    client.host_store = host_store
    client.actions_store = actions_store
    client.sec_store = sec_store
    yield client
    app.dependency_overrides.clear()


def test_reject_pending_writes_ai_actions_and_audit_log(reject_client: TestClient) -> None:
    rejected = _FakeHostRecord(
        id="act-reject-1",
        action_key="docker_ps",
        host="111",
        params={},
        summary="docker_ps on host 111 [read-only]",
    )
    reject_client.host_store.mark_rejected.return_value = rejected

    resp = reject_client.post(
        "/alfa-ai/api/admin/host-actions/act-reject-1/reject",
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["action"]["status"] == "rejected"

    reject_client.actions_store.record.assert_called_once()
    call = reject_client.actions_store.record.call_args
    assert call.args[0] == ACTION_HOST_ACTION_REJECTED
    assert "rejected" in call.args[1].lower()
    assert call.kwargs["created_by"] == "operator@example.com"
    detail = call.kwargs["detail"]
    assert detail["host_action_id"] == "act-reject-1"
    assert detail["action_key"] == "docker_ps"
    assert detail["host"] == "111"
    assert "risk_tier" in detail

    reject_client.sec_store.record_event.assert_called_once()
    sec_call = reject_client.sec_store.record_event.call_args
    assert sec_call.args[0] == "host_action_rejected"
    assert sec_call.kwargs["success"] is True
    assert sec_call.kwargs["user_id"] == "admin-1"
    assert "act-reject-1" in sec_call.kwargs["details"]


def test_reject_not_pending_returns_404(reject_client: TestClient) -> None:
    reject_client.host_store.mark_rejected.return_value = None

    resp = reject_client.post(
        "/alfa-ai/api/admin/host-actions/missing-or-done/reject",
        headers={"Authorization": "Bearer fake"},
    )

    assert resp.status_code == 404
    assert resp.json()["detail"] == "Pending host action not found"
    reject_client.actions_store.record.assert_not_called()
    reject_client.sec_store.record_event.assert_not_called()


def test_host_action_rejected_maps_to_host_category() -> None:
    assert category_for_action(ACTION_HOST_ACTION_REJECTED) == "host"
