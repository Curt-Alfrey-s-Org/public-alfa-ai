"""Version gate for the from-scratch PyTorch wheel check."""

from __future__ import annotations

import sys
from pathlib import Path

_PKG = Path(__file__).resolve().parents[1] / "train" / "from-scratch"
sys.path.insert(0, str(_PKG))

from check_wheel import wheel_problem  # noqa: E402


def test_wheel_problem_accepts_only_214_cu130() -> None:
    assert wheel_problem("2.14.0+cu130", "13.0") is None
    assert wheel_problem("2.12.0+cu130", "13.0") is not None
    assert wheel_problem("2.14.0+cu126", "12.6") is not None
    assert wheel_problem("2.14.0+cpu", None) is not None
