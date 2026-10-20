from __future__ import annotations

from pathlib import Path

import pytest

from src.runtime.error_catalog import append_entry, new_entry
from src.runtime.memory import append_mission_summary
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.preference_export import append_feedback
from src.runtime.queue import InMemoryQueue
from src.runtime.sleep_curator import (
    extract_lessons_from_blocks,
    run_sleep_curator,
)
from src.runtime.store import InMemoryStore


def test_extract_lessons() -> None:
    blocks = [
        "## 2026-07-11\n**Goal:** fix pool\n\n**Summary:**\nFixed wedge by ordered shard restart. Avoid nc -z probes.\n",
        "## 2026-07-10\n**Goal:** hi\n\n**Summary:**\nok\n",
    ]
    lessons = extract_lessons_from_blocks(blocks)
    assert any("Avoid" in x["lesson"] or "Fixed" in x["lesson"] for x in lessons)


def test_run_sleep_curator_writes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_MEMORY_MAX_ENTRIES", "50")

    append_mission_summary(
        "Deploy nginx",
        "Prefer hub-first tarballs. Never force-push production.",
        sources="docs/HUB_ARTIFACTS.md",
    )
    append_entry(new_entry(source="mission", summary="timeout on process", severity="medium"))
    append_feedback(
        prompt="How to start cluster?",
        response="Start-Stop-AlfaAi.ps1 on orchestrator",
        rating="up",
        alternative="restart random containers",
    )

    report = run_sleep_curator(dry_run=False)
    assert report.ok is True
    assert report.memory_files_touched >= 1
    assert (tmp_path / "data" / "lessons.md").is_file()
    assert (tmp_path / "data" / "errors-rollup.json").is_file()
    assert (tmp_path / "data" / "preference-pack.jsonl").is_file()
    assert (tmp_path / "data" / "morning-digest.md").is_file()
    assert (tmp_path / "data" / "sleep-curator-last.json").is_file()
    assert report.preference_pairs >= 1


def test_dry_run_no_last_json(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    report = run_sleep_curator(dry_run=True)
    assert report.ok is True
    assert report.dry_run is True
    assert not (tmp_path / "data" / "sleep-curator-last.json").exists()


def test_require_enabled_aborts(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_SLEEP_CURATOR_ENABLED", "0")
    report = run_sleep_curator(require_enabled_flag=True)
    assert report.ok is False


def test_skill_mission(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))

    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    run_id = orch.create_run("Nightly sleep curation", skill="sleep-curator")
    result = orch.process_next_task()
    assert result is not None
    assert result["status"] == "done"
    arts = store.list_artifacts_for_run(run_id)
    assert any(a.artifact_type == "sleep_curator_report" for a in arts)


def test_cli_dry_run(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    from scripts.sleep_curator_nightly import main

    assert main(["--dry-run"]) == 0
