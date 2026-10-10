from __future__ import annotations

from scripts.learning_loop_preflight import main, run_checks


def test_run_checks_all_pass() -> None:
    checks = run_checks()
    failed = [c for c in checks if not c["ok"]]
    assert not failed, failed


def test_cli() -> None:
    assert main([]) == 0
