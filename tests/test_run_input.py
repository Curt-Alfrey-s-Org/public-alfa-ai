from __future__ import annotations

from pathlib import Path

import pytest

from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.queue import InMemoryQueue
from src.runtime.run_input import RunInputError, materialize_run_input_files, sanitize_run_input_filename
from src.runtime.store import InMemoryStore


def test_sanitize_run_input_filename_rejects_traversal() -> None:
    with pytest.raises(RunInputError):
        sanitize_run_input_filename("../etc/passwd")
    assert sanitize_run_input_filename("solicitation.txt") == "solicitation.txt"


def test_materialize_run_input_files_writes_under_run_dir(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    written = materialize_run_input_files(
        "run-abc",
        [{"filename": "doc.md", "content": "# Hello"}],
    )
    assert written == ["runs/run-abc/input/doc.md"]
    assert (tmp_path / "runs/run-abc/input/doc.md").read_text(encoding="utf-8") == "# Hello"


def test_create_run_with_contracts_role_single_task(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)

    run_id = orch.create_run(
        "Analyze solicitation",
        role="contracts",
        input_files=[{"filename": "rfp.txt", "content": "Section L requirements"}],
    )
    tasks = store.list_tasks_for_run(run_id)
    assert len(tasks) == 1
    assert tasks[0].role == "contracts"
    assert (tmp_path / "runs" / run_id / "input" / "rfp.txt").is_file()
