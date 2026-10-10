from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from src.agent.loop import AgentRunResult
from src.api.app import app, set_orchestrator_for_tests
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore


def _patch_agent_loop(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_run_agent(*args, **kwargs):
        role = kwargs.get("role", "")
        if role == "coder":
            return AgentRunResult(text="Implemented feature in src/app.py.")
        return AgentRunResult(text="Research summary.\n\n## Sources\n- docs/README.md")

    monkeypatch.setattr("src.runtime.roles.run_agent", fake_run_agent)


def _make_test_client(monkeypatch, tmp_path: Path) -> TestClient:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    _patch_agent_loop(monkeypatch)
    orchestrator = RuntimeOrchestrator(store=InMemoryStore(), queue=InMemoryQueue())
    set_orchestrator_for_tests(orchestrator)
    return TestClient(app)


def test_create_and_get_run(monkeypatch, tmp_path: Path) -> None:
    client = _make_test_client(monkeypatch, tmp_path)

    created = client.post("/api/runs", json={"goal": "Create a parser"})
    assert created.status_code == 200
    run_id = created.json()["run_id"]

    fetched = client.get(f"/api/runs/{run_id}")
    assert fetched.status_code == 200
    body = fetched.json()
    assert body["ok"] is True
    assert body["run"]["run_id"] == run_id
    assert len(body["tasks"]) == 4


def test_process_next_endpoint(monkeypatch, tmp_path: Path) -> None:
    client = _make_test_client(monkeypatch, tmp_path)
    client.post("/api/runs", json={"goal": "Create an API"})

    processed = client.post("/api/runs/process-next")
    assert processed.status_code == 200
    assert processed.json()["ok"] is True


def test_run_artifacts_endpoint(monkeypatch, tmp_path: Path) -> None:
    client = _make_test_client(monkeypatch, tmp_path)
    created = client.post("/api/runs", json={"goal": "Build and document feature"})
    run_id = created.json()["run_id"]

    for _ in range(4):
        client.post("/api/runs/process-next")

    artifacts_response = client.get(f"/api/runs/{run_id}/artifacts")
    assert artifacts_response.status_code == 200
    body = artifacts_response.json()
    assert body["ok"] is True
    assert len(body["artifacts"]) == 4


def test_list_runs_endpoint(monkeypatch, tmp_path: Path) -> None:
    client = _make_test_client(monkeypatch, tmp_path)
    created = client.post(
        "/api/runs",
        json={"goal": "Audit deploy", "skill": "audit-repo", "research_only": True},
    )
    assert created.status_code == 200

    listed = client.get("/api/runs")
    assert listed.status_code == 200
    runs = listed.json()
    assert isinstance(runs, list)
    assert len(runs) == 1
    assert runs[0]["research_only"] is True


def test_ui_root_serves_html(monkeypatch, tmp_path: Path) -> None:
    client = _make_test_client(monkeypatch, tmp_path)
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers.get("content-type", "")
    assert "ALFa AI Control Panel" in response.text


def test_alfa_ai_prefixed_admin_health_is_api_not_spa(monkeypatch, tmp_path: Path) -> None:
    """www Admin Health uses /alfa-ai/api/admin/health (JWT) — must not return SPA index.html."""
    client = _make_test_client(monkeypatch, tmp_path)
    r = client.get("/alfa-ai/api/admin/health")
    assert r.status_code == 401
    assert "application/json" in (r.headers.get("content-type") or "")

