"""Operator console API: auth gate for /operator/api/*."""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from src.api import app as app_module


@pytest.fixture()
def client_with_auth_required(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "true")
    monkeypatch.setenv("ALFA_AI_API_TOKEN", "change-me")
    # Reload app dependency behavior picks up env at request time
    return TestClient(app_module.app)


def test_operator_config_401_without_bearer(client_with_auth_required: TestClient) -> None:
    r = client_with_auth_required.get("/operator/api/config")
    assert r.status_code == 401


def test_operator_config_200_with_bearer(client_with_auth_required: TestClient) -> None:
    r = client_with_auth_required.get(
        "/operator/api/config",
        headers={"Authorization": "Bearer test-operator-token-xyz"},
    )
    assert r.status_code == 200
    data = r.json()
    assert "chat_model" in data


def test_operator_chat_401_without_bearer(client_with_auth_required: TestClient) -> None:
    r = client_with_auth_required.post(
        "/operator/api/chat",
        json={"messages": [{"role": "user", "content": "hi"}]},
    )
    assert r.status_code == 401


def test_run_events_sse_401_without_token(client_with_auth_required: TestClient) -> None:
    r = client_with_auth_required.get("/api/runs/00000000-0000-0000-0000-000000000001/events")
    assert r.status_code == 401



