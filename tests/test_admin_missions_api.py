"""Tests for Admin Missions API (agent fleet read-only oversight)."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from src.agent.loop import AgentRunResult
from src.api.app import app, set_orchestrator_for_tests
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore


@pytest.fixture
def missions_client(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> TestClient:
    monkeypatch.setenv("ALFA_AI_JWT_SECRET", "change-me")
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_AUDIT_LOG_DIR", str(tmp_path / "audit-logs"))
    monkeypatch.delenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", raising=False)
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "false")

    def fake_run_agent(*args, **kwargs):
        return AgentRunResult(text="Audit complete.\n\n### Finding\nSample issue.")

    monkeypatch.setattr("src.runtime.roles.run_agent", fake_run_agent)

    orchestrator = RuntimeOrchestrator(store=InMemoryStore(), queue=InMemoryQueue())
    set_orchestrator_for_tests(orchestrator)

    from src.api.deps import get_current_user
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
    app.dependency_overrides[get_current_user] = lambda: admin

    client = TestClient(app)
    yield client
    app.dependency_overrides.clear()


@pytest.fixture
def anon_client(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> TestClient:
    monkeypatch.setenv("ALFA_AI_JWT_SECRET", "change-me")
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.delenv("ALFA_AI_ADMIN_ALLOWED_CIDRS", raising=False)
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "false")
    orchestrator = RuntimeOrchestrator(store=InMemoryStore(), queue=InMemoryQueue())
    set_orchestrator_for_tests(orchestrator)
    client = TestClient(app)
    yield client
    app.dependency_overrides.clear()


def test_missions_fleet_requires_admin(anon_client: TestClient) -> None:
    resp = anon_client.get("/alfa-ai/api/admin/missions/fleet")
    assert resp.status_code == 401


def test_missions_fleet_returns_catalog(missions_client: TestClient) -> None:
    resp = missions_client.get("/alfa-ai/api/admin/missions/fleet")
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["catalog_count"] >= 8
    ids = {row["id"] for row in body["fleet"]}
    assert "audit-repo" in ids
    assert "day-session-feeder" in ids
    audit = next(r for r in body["fleet"] if r["id"] == "audit-repo")
    assert audit["kind"] == "skill"
    assert audit["heartbeat_status"] == "unknown"


def test_missions_artifacts_summary_missing_dir_graceful(
    missions_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    missing = tmp_path / "no-such-audit-dir"
    monkeypatch.setenv("ALFA_AI_AUDIT_LOG_DIR", str(missing))
    resp = missions_client.get("/alfa-ai/api/admin/missions/artifacts/summary")
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["log_dir_accessible"] is False
    assert body["finding_count"] == 0


def test_missions_list_runs_after_create(missions_client: TestClient) -> None:
    created = missions_client.post(
        "/api/runs",
        json={"goal": "Audit deploy", "skill": "audit-repo", "research_only": True},
    )
    assert created.status_code == 200

    listed = missions_client.get("/alfa-ai/api/admin/missions/runs")
    assert listed.status_code == 200
    runs = listed.json()["runs"]
    assert len(runs) >= 1
    assert runs[0]["skill"] == "audit-repo"


def test_missions_run_detail_not_found(missions_client: TestClient) -> None:
    resp = missions_client.get("/alfa-ai/api/admin/missions/runs/does-not-exist")
    assert resp.status_code == 404


def test_missions_worker_status(missions_client: TestClient) -> None:
    resp = missions_client.get("/alfa-ai/api/admin/missions/worker")
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["status"] in ("busy", "idle", "unknown")


def test_missions_findings_inbox(
    missions_client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    log_dir = tmp_path / "audit-logs"
    log_dir.mkdir()
    monkeypatch.setenv("ALFA_AI_AUDIT_LOG_DIR", str(log_dir))
    from datetime import UTC, datetime

    today = datetime.now(tz=UTC).strftime("%Y-%m-%d")
    (log_dir / f"findings-{today}.md").write_text(
        "## Run a40d72ef-9ca2-4ede-a391-79ccc52f23e9\n\n"
        "### Finding 1 - Severity: bug\n"
        "- File: alfa-ai/deploy/x.yml:1\n"
        "- Description: Missing mount.\n"
        "- Suggestion: Bind-mount hub clone.\n",
        encoding="utf-8",
    )
    resp = missions_client.get("/alfa-ai/api/admin/missions/findings")
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["count"] >= 1
    assert body["findings"][0]["severity"] == "bug"
    assert body["findings"][0]["would_auto_apply"] is False
    assert "Bind-mount" in body["findings"][0]["would_take_action"]


def test_learning_loop_status_requires_admin(anon_client: TestClient) -> None:
    resp = anon_client.get("/alfa-ai/api/admin/learning-loop/status")
    assert resp.status_code == 401


def test_learning_loop_status_ok(
    missions_client: TestClient, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "alfa"))
    monkeypatch.setenv("ALFA_AI_LORA_REGISTRY_PATH", str(tmp_path / "lora.json"))
    monkeypatch.setenv("ALFA_AI_LORA_HUB_MANIFEST", str(tmp_path / "hub-missing.json"))
    resp = missions_client.get("/alfa-ai/api/admin/learning-loop/status")
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert "flywheel" in body
    assert "train_export" in body
    assert "lora" in body
