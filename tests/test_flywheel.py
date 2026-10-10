from __future__ import annotations

import json
from pathlib import Path

import pytest

from src.runtime.flywheel import run_data_flywheel


def test_flywheel_dry_run(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_DATA", str(tmp_path / "alfa"))
    report = run_data_flywheel(dry_run=True)
    assert report.ok
    assert any(p.phase == "monitor" for p in report.phases)
    assert any(p.phase == "execute" for p in report.phases)
    latest = tmp_path / "alfa" / "flywheel" / "LATEST.txt"
    assert latest.is_file()
    report_path = Path(latest.read_text(encoding="utf-8").strip())
    assert report_path.is_file()
    data = json.loads(report_path.read_text(encoding="utf-8"))
    assert data["dry_run"] is True
