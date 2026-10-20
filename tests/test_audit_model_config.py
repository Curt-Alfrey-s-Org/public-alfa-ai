"""Tests for scripts/audit_model_config.py drift detection."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_audit_committed_templates_passes() -> None:
    proc = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "audit_model_config.py"), "--skip-env"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_audit_flags_retired_default_in_env(tmp_path: Path) -> None:
    env = tmp_path / ".env"
    env.write_text("DEFAULT_MODEL=qwen3.5:27b\n", encoding="utf-8")
    proc = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts" / "audit_model_config.py"),
            "--env",
            str(env),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 1
    assert "LIVE_ENV_RETIRED_DEFAULT" in proc.stdout + proc.stderr


def test_manifest_matches_llm_config() -> None:
    manifest = json.loads(
        (ROOT / "deploy" / "model_config_manifest.json").read_text(encoding="utf-8")
    )
    from src.api import llm_config

    assert manifest["production_default"] == llm_config.PRODUCTION_DEFAULT_ALIAS
    assert list(llm_config._DEFAULT_PICKER_ALIASES) == manifest["picker_aliases"]
