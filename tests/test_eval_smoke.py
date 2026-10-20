from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from scripts.eval.smoke_runner import run, _SELF_CHECK_ANSWERS, DEFAULT_GOLD


def test_self_check_all_pass() -> None:
    report = run(gold_path=DEFAULT_GOLD, answers=_SELF_CHECK_ANSWERS)
    assert report["total"] >= 10
    assert report["ok"] is True
    assert report["passed"] == report["total"]


def test_cli_self_check() -> None:
    repo = Path(__file__).resolve().parents[1]
    proc = subprocess.run(
        [sys.executable, str(repo / "scripts" / "eval" / "smoke_runner.py"), "--self-check"],
        cwd=str(repo),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "10/10" in proc.stdout or "pass_rate" in proc.stdout or "10" in proc.stdout


def test_preference_export(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path))
    from src.runtime.preference_export import append_feedback, export_preference_pack

    append_feedback(
        prompt="How to stop inference?",
        response="Use Start-Stop-AlfaAi.ps1 on orchestrator",
        rating="up",
        alternative="docker restart randomly",
    )
    report = export_preference_pack()
    assert report["ok"] is True
    assert report["pairs"] >= 1
    assert Path(report["path"]).is_file()
