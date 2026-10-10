"""POST /api/runs must not echo raw exception text (org code review 2026-09-25, low)."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from src.api.app import app, set_orchestrator_for_tests
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore

_LEAK = "postgresql://alfa@hub/alfa_ai relation runs"


def test_create_run_500_hides_exception_text(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "false")
    orchestrator = RuntimeOrchestrator(store=InMemoryStore(), queue=InMemoryQueue())

    def boom(**kwargs):
        raise RuntimeError(_LEAK)

    monkeypatch.setattr(orchestrator, "create_run", boom)
    set_orchestrator_for_tests(orchestrator)
    r = TestClient(app).post("/api/runs", json={"goal": "x"})
    assert r.status_code == 500
    detail = r.json()["detail"]
    assert "hunter2" not in detail
    assert _LEAK not in detail
    assert "see API logs" in detail
    assert "ensure-runtime-schema.sh" in detail
