from __future__ import annotations

import json
from pathlib import Path

import pytest

from src.runtime.learning_loop_status import collect_learning_loop_status
from src.runtime.lora_registry import list_adapters, sync_registry_from_hub
from src.runtime.preference_export import append_thumbs, load_feedback_rows, pairs_from_feedback


def test_collect_learning_loop_status(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    data = tmp_path / "alfa"
    monkeypatch.setenv("ALFA_AI_DATA", str(data))
    monkeypatch.setenv("ALFA_AI_FLYWHEEL_ENABLED", "1")
    monkeypatch.setenv("ALFA_AI_LORA_REGISTRY_PATH", str(tmp_path / "brain-lora.json"))
    monkeypatch.setenv("ALFA_AI_LORA_HUB_MANIFEST", str(tmp_path / "missing-hub.json"))

    fly = data / "flywheel"
    fly.mkdir(parents=True)
    report = {
        "ok": True,
        "started_at": "t0",
        "finished_at": "t1",
        "dry_run": False,
        "notes": ["n1"],
        "phases": [{"phase": "monitor", "ok": True, "summary": "ok"}],
    }
    report_path = fly / "flywheel-1.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")
    (fly / "LATEST.txt").write_text(str(report_path) + "\n", encoding="utf-8")

    pack = data / "train-export" / "pack1"
    pack.mkdir(parents=True)
    (pack / "MANIFEST.json").write_text(
        json.dumps(
            {
                "schema_version": "1",
                "counts": {"dpo_rows": 2},
                "scan_pass": {"ok": True},
                "base_model_target": "qwen3.6-27b",
            }
        ),
        encoding="utf-8",
    )
    (data / "train-export" / "LATEST.txt").write_text(str(pack) + "\n", encoding="utf-8")

    status = collect_learning_loop_status()
    assert status["ok"] is True
    assert status["flywheel"]["enabled"] is True
    assert status["flywheel"]["latest"]["ok"] is True
    assert status["flywheel"]["latest"]["phases"][0]["phase"] == "monitor"
    assert status["train_export"]["schema_version"] == "1"
    assert status["train_export"]["counts"]["dpo_rows"] == 2
    assert status["lora"]["count"] == 0
    assert status["lora"]["hub_manifest_present"] is False


def test_append_thumbs_builds_preference_pair(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    inbox = tmp_path / "feedback.jsonl"
    monkeypatch.setenv("ALFA_AI_FEEDBACK_JSONL", str(inbox))
    append_thumbs(
        prompt="fix the alert",
        response="restart shard",
        helpful=False,
        source="admin-proposal",
        metadata={"proposal_id": "p1"},
    )
    append_thumbs(
        prompt="fix the alert",
        response="full stop then start",
        helpful=True,
        source="admin-proposal",
        metadata={"proposal_id": "p2"},
    )
    rows = load_feedback_rows()
    assert len(rows) == 2
    pairs = pairs_from_feedback(rows)
    assert len(pairs) == 1
    assert pairs[0].chosen == "full stop then start"
    assert pairs[0].rejected == "restart shard"


def test_sync_registry_from_hub_clamps_low_eval(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    brain = tmp_path / "brain-lora.json"
    hub = tmp_path / "hub-lora.json"
    monkeypatch.setenv("ALFA_AI_LORA_REGISTRY_PATH", str(brain))
    monkeypatch.setenv("ALFA_AI_LORA_MIN_EVAL_SCORE", "0.70")
    hub.write_text(
        json.dumps(
            {
                "adapters": [
                    {
                        "adapter_id": "good",
                        "base_model": "qwen3.6-27b",
                        "gguf_relpath": "qwen36/good.gguf",
                        "eval_score": 0.81,
                        "promoted": True,
                    },
                    {
                        "adapter_id": "low",
                        "base_model": "qwen3.6-27b",
                        "gguf_relpath": "qwen36/low.gguf",
                        "eval_score": 0.40,
                        "promoted": True,
                    },
                    {"adapter_id": "", "gguf_relpath": "skip.gguf"},
                ]
            }
        ),
        encoding="utf-8",
    )
    result = sync_registry_from_hub(hub_manifest=hub)
    assert result["ok"] is True
    assert result["imported"] == 2
    assert result["skipped"] == 1
    by_id = {a.adapter_id: a for a in list_adapters()}
    assert by_id["good"].promoted is True
    assert by_id["low"].promoted is False
