from __future__ import annotations

from pathlib import Path

import pytest

from src.runtime.lora_registry import (
    best_adapter_for_base,
    list_adapters,
    min_eval_score,
    register_adapter,
)


def test_lora_registry_register_and_best(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    reg = tmp_path / "lora-adapters.json"
    monkeypatch.setenv("ALFA_AI_LORA_REGISTRY_PATH", str(reg))
    monkeypatch.setenv("ALFA_AI_LORA_MIN_EVAL_SCORE", "0.70")

    register_adapter(
        adapter_id="a-low",
        base_model="qwen3.6-27b",
        gguf_relpath="qwen36/a-low.gguf",
        eval_score=0.72,
        promoted=True,
    )
    register_adapter(
        adapter_id="a-high",
        base_model="qwen3.6-27b",
        gguf_relpath="qwen36/a-high.gguf",
        eval_score=0.81,
        promoted=True,
    )
    assert len(list_adapters()) == 2
    best = best_adapter_for_base("qwen3.6-27b")
    assert best is not None
    assert best.adapter_id == "a-high"


def test_lora_registry_rejects_low_eval_promote(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    reg = tmp_path / "lora-adapters.json"
    monkeypatch.setenv("ALFA_AI_LORA_REGISTRY_PATH", str(reg))
    monkeypatch.setenv("ALFA_AI_LORA_MIN_EVAL_SCORE", "0.70")
    with pytest.raises(ValueError):
        register_adapter(
            adapter_id="bad",
            base_model="qwen3.6-27b",
            gguf_relpath="qwen36/bad.gguf",
            eval_score=0.50,
            promoted=True,
        )
    assert min_eval_score() == 0.70
