from __future__ import annotations

from pathlib import Path

from src.runtime import memory


def test_append_and_load_memory(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path / "repo"))
    (tmp_path / "repo").mkdir()
    memory.append_mission_summary(
        "Research FastAPI lifespan",
        "Use lifespan context managers instead of on_event.",
        "- docs/AGENT_RESEARCH_TOOLS.md",
    )
    loaded = memory.load_memory()
    assert "Research FastAPI lifespan" in loaded
    assert "lifespan context managers" in loaded


def test_list_recent_mission_summaries(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path / "repo"))
    (tmp_path / "repo").mkdir()
    memory.append_mission_summary("Goal A", "Summary A", "- a.md")
    memory.append_mission_summary("Goal B", "Summary B", "- b.md")
    recent = memory.list_recent_mission_summaries(limit=2)
    assert len(recent) == 2
    assert recent[0]["goal"] == "Goal B"
    assert recent[1]["goal"] == "Goal A"


def test_build_memory_prompt_includes_recent(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path / "repo"))
    (tmp_path / "repo").mkdir()
    memory.append_mission_summary("Prior goal", "Prior summary", "- x.md")
    prompt = memory.build_memory_prompt("researcher")
    assert "## Recent missions" in prompt
    assert "Prior goal" in prompt
    assert memory.build_memory_prompt("debugger") == ""


def test_memory_trim_drops_oldest(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path / "repo"))
    monkeypatch.setenv("ALFA_AI_MEMORY_MAX_ENTRIES", "5")
    (tmp_path / "repo").mkdir()
    for idx in range(6):
        memory.append_mission_summary(f"Goal-{idx}", f"Summary-{idx}")
    recent = memory.list_recent_mission_summaries(limit=10)
    goals = [item["goal"] for item in recent]
    assert goals == ["Goal-5", "Goal-4", "Goal-3", "Goal-2", "Goal-1"]
