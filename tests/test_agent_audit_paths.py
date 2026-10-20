"""Tests for agent read paths across audit roots."""

from __future__ import annotations

from pathlib import Path

import pytest

from src.agent.tools import glob_files, grep_repo


@pytest.fixture
def audit_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    workspace = tmp_path / "workspace"
    repo = tmp_path / "hub-repo"
    workspace.mkdir()
    repo.mkdir()
    (repo / "deploy").mkdir()
    (repo / "docs").mkdir()
    (repo / "deploy" / "compose.yml").write_text("services:\n", encoding="utf-8")
    (repo / "docs" / "README.md").write_text("# docs\n", encoding="utf-8")
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(workspace))
    monkeypatch.setenv("ALFA_AI_AUDIT_ROOTS", f"alfa-ai={repo}")
    return repo


def test_glob_files_audit_root_prefix(audit_env: Path) -> None:
    result = glob_files("*.md", path="alfa-ai/docs")
    assert result["ok"] is True
    assert "alfa-ai/docs/README.md" in result["paths"]


def test_glob_files_fallback_deploy_path(audit_env: Path) -> None:
    result = glob_files("*.yml", path="deploy")
    assert result["ok"] is True
    assert result["paths"] == ["alfa-ai/deploy/compose.yml"]


@pytest.mark.skipif(
    __import__("shutil").which("rg") is None,
    reason="ripgrep not installed on test host",
)
def test_grep_repo_audit_root(audit_env: Path) -> None:
    result = grep_repo("services", path="alfa-ai/deploy")
    assert result["ok"] is True
    assert result["matches"]
    assert result["matches"][0]["file"].startswith("alfa-ai/deploy")
