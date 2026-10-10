"""Tests for Grok Bot audit excerpt formatting."""

from __future__ import annotations

from src.ops.bot_audit_excerpt import format_bot_audit_excerpt


def test_bot_audit_excerpt_includes_exit_and_metadata() -> None:
    excerpt = format_bot_audit_excerpt(
        action_key="brain_verify",
        host="111",
        exit_code=0,
        stdout="PASS\nline2",
        stderr="",
    )
    assert "action_key: brain_verify" in excerpt
    assert "host: 111" in excerpt
    assert "Exit: 0" in excerpt
    assert "PASS" in excerpt
    assert "Do not dump files" in excerpt


def test_bot_audit_excerpt_truncates_long_stdout() -> None:
    stdout = "\n".join(f"line-{i}" for i in range(200))
    excerpt = format_bot_audit_excerpt(
        action_key="ps_syntax_check",
        host="93",
        exit_code=1,
        stdout=stdout,
        stderr=None,
    )
    assert "Exit: 1" in excerpt
    assert "line-199" in excerpt
    assert "line-0" not in excerpt
    assert excerpt.count("line-") == 80


def test_bot_audit_excerpt_includes_stderr_tail() -> None:
    stderr = "\n".join(f"err-{i}" for i in range(60))
    excerpt = format_bot_audit_excerpt(
        action_key="hub_diag_read",
        host="148",
        exit_code=2,
        stdout="ok",
        stderr=stderr,
    )
    assert "--- stderr (last 40 lines) ---" in excerpt
    assert "err-59" in excerpt
    assert "err-0" not in excerpt
