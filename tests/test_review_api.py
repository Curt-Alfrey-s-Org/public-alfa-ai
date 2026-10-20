from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from src.agent.loop import AgentRunResult
from src.runtime.review_parse import parse_review_issues
from src.runtime.review_service import resolve_review_root


def test_parse_review_issues_structured() -> None:
    text = """
Some intro.

### Issue 1 — Severity: bug
- File: src/api/auth.py:42
- Description: Missing auth check
- Suggestion: Add require_role
- Status: open

### Issue 2 — Severity: nit
- File: README.md:1
- Description: Typo
- Suggestion: Fix spelling
- Status: open
"""
    issues = parse_review_issues(text)
    assert len(issues) == 2
    assert issues[0]["severity"] == "bug"
    assert issues[0]["file"] == "src/api/auth.py"
    assert issues[0]["line"] == 42
    assert "Missing auth" in issues[0]["description"]


def test_resolve_review_root_workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.delenv("ALFA_AI_AUDIT_ROOTS", raising=False)
    root = resolve_review_root("workspace")
    assert root == tmp_path.resolve()


def test_resolve_review_root_audit_map(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = tmp_path / "contracts-bot"
    repo.mkdir()
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_AUDIT_ROOTS", f"contracts-bot={repo}")
    assert resolve_review_root("contracts-bot") == repo.resolve()


def test_agent_review_endpoint(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "true")
    monkeypatch.setenv("ALFA_AI_API_TOKEN", "change-me")
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.delenv("ALFA_AI_AUDIT_ROOTS", raising=False)

    def fake_run_agent(*args, **kwargs):
        return AgentRunResult(
            text=(
                "### Issue 1 — Severity: suggestion\n"
                "- File: app.py:1\n"
                "- Description: Consider health check\n"
                "- Suggestion: Add /healthz\n"
                "- Status: open\n"
            )
        )

    monkeypatch.setattr("src.runtime.review_service.run_agent", fake_run_agent)

    from src.api.app import app

    client = TestClient(app)
    r = client.post(
        "/api/agent/review",
        headers={"Authorization": "Bearer unit-test-secret"},
        json={"repo": "workspace", "goal": "Quick review", "focus": "correctness"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ok"] is True
    assert len(body["issues"]) >= 1
    assert body["issues"][0]["severity"] == "suggestion"


def test_agent_review_401(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_REQUIRE_API_AUTH", "true")
    monkeypatch.setenv("ALFA_AI_API_TOKEN", "change-me")
    from src.api.app import app

    client = TestClient(app)
    r = client.post("/api/agent/review", json={"repo": "workspace"})
    assert r.status_code == 401
