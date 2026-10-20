"""Bearer auth dependency used by ALFa AI orchestrator /api/runs."""

from __future__ import annotations

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from src.api.auth_deps import (
    require_alfa_ai_api_token,
    require_brain_operator_health_auth,
)

app = FastAPI()


@app.post("/_auth_probe")
def _auth_probe(_: None = Depends(require_alfa_ai_api_token)) -> dict[str, str]:
    return {"ok": "true"}


@app.get("/_brain_probe")
def _brain_probe(_: None = Depends(require_brain_operator_health_auth)) -> dict[str, str]:
    return {"ok": "true"}


client = TestClient(app)


def test_probe_401_when_auth_enabled_without_bearer(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "true")
    monkeypatch.setenv("ALFA_AI_API_TOKEN", "change-me")
    r = client.post("/_auth_probe")
    assert r.status_code == 401


def test_probe_200_with_valid_bearer(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "true")
    monkeypatch.setenv("ALFA_AI_API_TOKEN", "change-me")
    r = client.post(
        "/_auth_probe",
        headers={"Authorization": "Bearer unit-test-secret"},
    )
    assert r.status_code == 200
    assert r.json() == {"ok": "true"}


def test_probe_200_when_auth_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "false")
    monkeypatch.delenv("ALFA_AI_API_TOKEN", raising=False)
    r = client.post("/_auth_probe")
    assert r.status_code == 200


def test_brain_probe_locked_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "false")
    monkeypatch.delenv("ALFA_AI_LOCK_OPERATOR_HEALTH", raising=False)
    monkeypatch.delenv("ALFA_AI_API_TOKEN", raising=False)
    r = client.get("/_brain_probe")
    assert r.status_code == 401


def test_brain_probe_open_when_not_locked(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "false")
    monkeypatch.setenv("ALFA_AI_LOCK_OPERATOR_HEALTH", "false")
    monkeypatch.delenv("ALFA_AI_API_TOKEN", raising=False)
    r = client.get("/_brain_probe")
    assert r.status_code == 200


def test_brain_probe_401_when_locked_without_bearer(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "false")
    monkeypatch.setenv("ALFA_AI_LOCK_OPERATOR_HEALTH", "true")
    r = client.get("/_brain_probe")
    assert r.status_code == 401


def test_brain_probe_200_with_api_token_when_lock_only(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "false")
    monkeypatch.setenv("ALFA_AI_LOCK_OPERATOR_HEALTH", "true")
    monkeypatch.setenv("ALFA_AI_API_TOKEN", "change-me")
    r = client.get(
        "/_brain_probe",
        headers={"Authorization": "Bearer brain-secret"},
    )
    assert r.status_code == 200
