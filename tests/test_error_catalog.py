from __future__ import annotations

from pathlib import Path

from src.runtime.error_catalog import (
    append_entry,
    corrective_actions_markdown,
    load_entries,
    make_fingerprint,
    new_entry,
    record_mission_failure,
    rollup_by_fingerprint,
    write_rollup_json,
)
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore
from src.agent.loop import AgentRunResult


def test_fingerprint_stable() -> None:
    a = make_fingerprint(source="mission", repo="alfa-ai", summary="Timeout on  abc  ")
    b = make_fingerprint(source="mission", repo="alfa-ai", summary="timeout on abc")
    assert a == b


def test_append_merges_by_fingerprint(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    e1 = new_entry(source="pytest", summary="assert failed", repo="alfa-ai", severity="high")
    e2 = new_entry(source="pytest", summary="assert failed", repo="alfa-ai", severity="high")
    append_entry(e1)
    merged = append_entry(e2)
    assert merged.count == 2
    assert len(load_entries()) == 1


def test_corrective_actions_markdown(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    append_entry(new_entry(source="lint", summary="unused import", severity="low"))
    md = corrective_actions_markdown()
    assert "Corrective actions" in md
    assert "Acceptance" in md


def test_record_mission_failure(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    entry = record_mission_failure(
        run_id="r1",
        task_id="t1",
        role="coder",
        summary="edit_file blocked",
    )
    assert entry.source == "mission"
    assert entry.fingerprint


def test_error_cataloger_skill_run(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))

    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    run_id = orch.create_run("Catalog recent errors", skill="error-cataloger")
    result = orch.process_next_task()
    assert result is not None
    assert result["status"] == "done"
    artifacts = store.list_artifacts_for_run(run_id)
    assert any(a.artifact_type == "error_catalog" for a in artifacts)
    assert (tmp_path / "data" / "errors.jsonl").is_file()


def test_corrective_analyst_skill_run(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    append_entry(new_entry(source="incident", summary="inference wedge", severity="critical"))

    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    run_id = orch.create_run("Propose fixes", skill="corrective-analyst")
    result = orch.process_next_task()
    assert result is not None
    assert result["status"] == "done"
    artifacts = store.list_artifacts_for_run(run_id)
    assert any(a.artifact_type == "corrective_actions" for a in artifacts)


def test_failed_task_writes_catalog(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))

    def boom(*args, **kwargs):
        return AgentRunResult(text="")

    monkeypatch.setattr("src.runtime.roles.run_agent", boom)

    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    orch.create_run("Do research", research_only=True)
    result = orch.process_next_task()
    assert result is not None
    assert result["status"] == "failed"
    entries = load_entries()
    assert any(e.source == "mission" for e in entries)


def test_rollup_json(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path))
    append_entry(new_entry(source="eval", summary="smoke fail", severity="medium"))
    path = write_rollup_json()
    assert path.is_file()
    ranked = rollup_by_fingerprint()
    assert len(ranked) >= 1
