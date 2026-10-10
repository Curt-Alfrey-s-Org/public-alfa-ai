from __future__ import annotations

import json
from pathlib import Path

import pytest

from src.runtime.error_catalog import append_entry, new_entry
from src.runtime.orchestrator import RuntimeOrchestrator
from src.runtime.preference_export import append_feedback
from src.runtime.queue import InMemoryQueue
from src.runtime.store import InMemoryStore
from src.runtime.train_export import (
    MANIFEST_SCHEMA_VERSION,
    export_train_pack,
    lessons_to_chat_jsonl,
    patch_manifest_scan_pass,
    preference_to_dpo_jsonl,
)


def test_preference_to_dpo(tmp_path: Path) -> None:
    src = tmp_path / "pref.jsonl"
    src.write_text(
        json.dumps(
            {
                "prompt": "How start?",
                "chosen": "Use Start-Stop script",
                "rejected": "rm -rf",
            }
        )
        + "\n",
        encoding="utf-8",
    )
    out = tmp_path / "dpo.jsonl"
    assert preference_to_dpo_jsonl(src, out) == 1
    row = json.loads(out.read_text(encoding="utf-8").strip())
    assert row["chosen"] == "Use Start-Stop script"
    assert "chosen_response" in row


def test_lessons_to_chat(tmp_path: Path) -> None:
    lessons = tmp_path / "lessons.md"
    lessons.write_text(
        "# lessons\n\n## Lesson 1\n- **From goal:** fix pool\n"
        "- **Lesson:** Avoid nc -z after coordinator connect\n",
        encoding="utf-8",
    )
    out = tmp_path / "chat.jsonl"
    assert lessons_to_chat_jsonl(lessons, out) == 1


def test_export_train_pack(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    (tmp_path / "data").mkdir(parents=True)
    (tmp_path / "data" / "lessons.md").write_text(
        "## Lesson 1\n- **From goal:** g\n- **Lesson:** Prefer hub-first\n",
        encoding="utf-8",
    )
    append_feedback(
        prompt="stop cluster?",
        response="orchestrator stop",
        rating="up",
        alternative="kill -9 random",
    )
    append_entry(new_entry(source="mission", summary="wedge", severity="high"))

    report = export_train_pack()
    assert report.ok is True
    export_dir = Path(report.export_dir)
    manifest_path = export_dir / "MANIFEST.json"
    assert manifest_path.is_file()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["schema_version"] == MANIFEST_SCHEMA_VERSION
    assert manifest["base_model_target"] == "qwen3.6-27b"
    assert manifest["pack_id"] == export_dir.name
    for entry in (manifest.get("files") or {}).values():
        path_val = entry.get("path", "")
        assert path_val and not path_val.startswith("/") and ":" not in path_val[:3]
    assert (export_dir / "preference-dpo.jsonl").is_file()
    assert report.counts.get("dpo_rows", 0) >= 1
    latest = tmp_path / "data" / "train-export" / "LATEST.txt"
    assert latest.is_file()


def test_export_train_pack_base_model_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_TRAIN_BASE_MODEL", "qwen3-coder-next-80b")
    (tmp_path / "data").mkdir(parents=True)
    report = export_train_pack()
    manifest = json.loads((Path(report.export_dir) / "MANIFEST.json").read_text(encoding="utf-8"))
    assert manifest["base_model_target"] == "qwen3-coder-next-80b"


def test_patch_manifest_scan_pass(tmp_path: Path) -> None:
    manifest_path = tmp_path / "MANIFEST.json"
    manifest_path.write_text(
        json.dumps({"schema_version": MANIFEST_SCHEMA_VERSION, "files": {}}) + "\n",
        encoding="utf-8",
    )
    patch_manifest_scan_pass(
        manifest_path,
        {"ok": True, "hit_count": 0, "pack_dir": str(tmp_path)},
    )
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert data["scan_pass"]["ok"] is True
    assert data["scan_pass"]["hit_count"] == 0
    assert "scan_pass_jsonl" in data["scan_pass"]["tool"]


def test_skill_export_train_pack(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "data"))
    store = InMemoryStore()
    queue = InMemoryQueue()
    orch = RuntimeOrchestrator(store=store, queue=queue)
    run_id = orch.create_run("Export pack", skill="export-train-pack")
    result = orch.process_next_task()
    assert result is not None
    assert result["status"] == "done"
    arts = store.list_artifacts_for_run(run_id)
    assert any(a.artifact_type == "train_export_report" for a in arts)
