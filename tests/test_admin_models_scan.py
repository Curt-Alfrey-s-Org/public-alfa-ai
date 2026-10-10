"""Tests for hub model directory scanning."""

from __future__ import annotations

from pathlib import Path

import pytest

from src.api.routers import admin as admin_module


def test_scan_models_dir_hf_hub_layout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    models_root = tmp_path / "models"
    hf_dir = models_root / "huggingface" / "hub" / "models--Qwen--Qwen3.6-27B"
    hf_dir.mkdir(parents=True)
    (hf_dir / "config.json").write_text("{}", encoding="utf-8")

    monkeypatch.setattr(admin_module, "_MODELS_DIR", models_root)
    found = admin_module._scan_models_dir()
    assert len(found) == 1
    assert found[0]["name"] == "Qwen/Qwen3.6-27B"
    assert found[0]["type"] == "huggingface"


def test_scan_models_dir_gguf(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    models_root = tmp_path / "models"
    gguf_root = tmp_path / "llama-cpp" / "models"
    gguf_root.mkdir(parents=True)
    (gguf_root / "Qwen3.5-122B-A10B-Q3_K_M.gguf").write_bytes(b"x" * 1024)

    monkeypatch.setattr(admin_module, "_MODELS_DIR", models_root)
    found = admin_module._scan_models_dir()
    assert any(m["type"] == "llama-cpp" for m in found)
