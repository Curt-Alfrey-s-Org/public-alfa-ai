"""Tests for cluster FAQ chat JSONL builder (OpenAI messages; --repeats preprocess)."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from scripts.build_7b_cluster_faq_chat import GATE_FACT13_INDICES, UNIQUE_TURNS, build_rows

_REPO = Path(__file__).resolve().parents[1]

# Frozen live-gate prompts (ALFA_7B_SERVE_ALONGSIDE_27B.md) -- do not change.
_FROZEN_LIVE_GATE_USER_PROMPTS: tuple[str, ...] = (
    "Can I attach this 7B LoRA to the 27B inference coordinator?",
    "Can I apply pool-7b-qlora-v2.gguf onto frontier-code or qwen3.6-27b?",
    "Can I run 7B QLoRA training and this 7B llama-server on Colin (gaming-c) at the same time?",
)


def test_unique_covers_failed_ops_and_smoke_misses() -> None:
    blob = "\n".join(a for _, a in UNIQUE_TURNS)
    for needle in (
        "No.",
        "8470",
        "mutually exclusive",
        "workflow.py",
        "plan_implement_review_fix",
        "VERDICT: PASS",
        "VERDICT: FAIL",
        "ALFA_AI_AGENT_MUTATE_ENABLED",
        "gaming-c",
        "gaming-b",
        "gaming-a",
        "inference is not a train rank",
    ):
        assert needle in blob, needle


def _assistant_for(user_substr: str) -> str:
    for user, assistant in UNIQUE_TURNS:
        if user_substr in user:
            return assistant
    raise AssertionError("missing user turn: " + user_substr)


def test_frozen_live_gate_user_prompts_unchanged() -> None:
    assert tuple(user for user, _ in UNIQUE_TURNS[:3]) == _FROZEN_LIVE_GATE_USER_PROMPTS


def test_failed_yes_no_turns_start_with_no() -> None:
    attach = _assistant_for("attach this 7B LoRA to the 27B")
    frontier = _assistant_for("frontier-code use this 7B LoRA")
    mutex = _assistant_for("7B QLoRA training and this 7B llama-server")
    mutex_para = _assistant_for("Start-Alfa7bServe while the 7B trainer")
    assert attach.startswith("No.")
    assert frontier.startswith("No.")
    assert mutex.startswith("No.")
    assert mutex_para.startswith("No.")
    assert "8470" in attach
    assert "mutually exclusive" in mutex


def test_sft_paraphrases_after_live_gate() -> None:
    """Indices 3-8 are two paraphrases per live-gate fact; assistants start with No."""
    assert len(UNIQUE_TURNS) == 16
    paraphrase_users = [user for user, _ in UNIQUE_TURNS[3:9]]
    for user, assistant in UNIQUE_TURNS[3:9]:
        assert assistant.startswith("No."), user
    assert any("inference coordinator" in u for u in paraphrase_users)
    assert any("frontier-code" in u for u in paraphrase_users)
    assert any("Start-Alfa7bServe" in u for u in paraphrase_users)


def test_build_rows_repeats() -> None:
    rows = build_rows(3)
    assert len(rows) == 3 * len(UNIQUE_TURNS)
    assert rows[0]["messages"][0]["role"] == "user"
    assert rows[0]["messages"][1]["role"] == "assistant"


def test_build_rows_extra_gate_fact13() -> None:
    rows = build_rows(2, extra_repeats_gate_fact13=3)
    expected = 2 * len(UNIQUE_TURNS) + 3 * len(GATE_FACT13_INDICES)
    assert len(rows) == expected


def test_cli_writes_jsonl(tmp_path: Path) -> None:
    out = tmp_path / "faq.jsonl"
    proc = subprocess.run(
        [
            sys.executable,
            str(_REPO / "scripts" / "build_7b_cluster_faq_chat.py"),
            "--out",
            str(out),
            "--repeats",
            "2",
            "--extra-repeats-gate-fact13",
            "0",
        ],
        cwd=str(_REPO),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    lines = [ln for ln in out.read_text(encoding="utf-8").splitlines() if ln.strip()]
    assert len(lines) == 2 * len(UNIQUE_TURNS)
    row = json.loads(lines[0])
    assert row["messages"][0]["role"] == "user"
    assert "OK unique=" in proc.stdout
