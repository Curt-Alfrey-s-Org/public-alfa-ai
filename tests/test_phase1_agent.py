from __future__ import annotations

from pathlib import Path

import pytest

from src.agent.tools import read_file
from src.runtime.mission_events import mission_event_bus


def test_audit_root_read_path(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    workspace = tmp_path / "workspace"
    audit = tmp_path / "audit-repo"
    workspace.mkdir()
    audit.mkdir()
    (audit / "secret.txt").write_text("audit content", encoding="utf-8")

    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(workspace))
    monkeypatch.setenv("ALFA_AI_AUDIT_ROOTS", f"contracts-bot={audit}")

    result = read_file("contracts-bot/secret.txt")
    assert result["ok"] is True
    assert "audit content" in result["content"]


def test_mission_event_bus_get_since() -> None:
    mission_event_bus.publish("run-1", "tool_start", {"tool": "grep_repo"})
    mission_event_bus.publish("run-1", "tool_end", {"tool": "grep_repo", "ok": True})
    batch, offset = mission_event_bus.get_since("run-1", 0)
    assert len(batch) == 2
    assert offset == 2
    more, offset2 = mission_event_bus.get_since("run-1", offset)
    assert more == []
    assert offset2 == 2