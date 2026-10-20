"""Tests for live 7B FAQ Yes/No polarity helper (no llama-server)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from scripts.build_7b_cluster_faq_chat import UNIQUE_TURNS
from scripts.eval.live_7b_faq_gate import (
    LIVE_GATE_TURNS,
    expected_yes_no,
    first_yes_no,
    run_self_check,
)

_REPO = Path(__file__).resolve().parents[1]

_FROZEN = (
    "Can I attach this 7B LoRA to the 27B inference coordinator?",
    "Can I apply pool-7b-qlora-v2.gguf onto frontier-code or qwen3.6-27b?",
    "Can I run 7B QLoRA training and this 7B llama-server on Colin (gaming-c) at the same time?",
)


def test_live_gate_is_first_three_unique_turns() -> None:
    assert LIVE_GATE_TURNS == UNIQUE_TURNS[:3]
    assert tuple(u for u, _ in LIVE_GATE_TURNS) == _FROZEN


def test_expected_polarity_is_no() -> None:
    for user, assistant in LIVE_GATE_TURNS:
        assert expected_yes_no(assistant) == "no", user


def test_first_yes_no_tokens() -> None:
    assert first_yes_no("No. The 7B LoRA serves only on :8470.") == "no"
    assert first_yes_no("**No** do not attach") == "no"
    assert first_yes_no("Yes, attach it to the coordinator") == "yes"
    assert first_yes_no("  yes.") == "yes"
    assert first_yes_no("Maybe the 35B MoE") is None
    assert first_yes_no("") is None


def test_self_check_exit_zero() -> None:
    assert run_self_check() == 0


def test_cli_self_check() -> None:
    script = _REPO / "scripts" / "eval" / "live_7b_faq_gate.py"
    proc = subprocess.run(
        [sys.executable, str(script), "--self-check"],
        cwd=str(_REPO),
        check=False,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    assert "self-check OK" in proc.stdout
