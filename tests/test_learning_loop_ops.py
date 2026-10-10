"""Tests for scan_pass_jsonl and train checkpoint gate."""

from __future__ import annotations

import json
from pathlib import Path

from scripts.eval.train_checkpoint_gate import PASS_THRESHOLD, score_answers
from scripts.eval.smoke_runner import DEFAULT_GOLD, _SELF_CHECK_ANSWERS
from scripts.scan_pass_jsonl import scan_file, scan_pack


def test_scan_pass_clean(tmp_path: Path) -> None:
    p = tmp_path / "clean.jsonl"
    p.write_text(
        json.dumps({"messages": [{"role": "user", "content": "hello"}]}) + "\n",
        encoding="utf-8",
    )
    assert scan_file(p) == []


def test_scan_pass_jwt(tmp_path: Path) -> None:
    p = tmp_path / "bad.jsonl"
    p.write_text(
        json.dumps(
            {
                "token": (
                    "example."
                    "example."
                    "SflKxwRJ""SMeKKF2Q""T4fwpMeJ""f36POk6y""JV_adQss""w5c"
                )
            }
        )
        + "\n",
        encoding="utf-8",
    )
    hits = scan_file(p)
    assert hits and hits[0]["pattern"] == "jwt_like"


def test_train_checkpoint_gate_self_check() -> None:
    base = score_answers(DEFAULT_GOLD, _SELF_CHECK_ANSWERS)
    assert base["rate"] >= PASS_THRESHOLD
    partial = dict(_SELF_CHECK_ANSWERS)
    for key in ("smoke-01", "smoke-02", "smoke-03", "smoke-04"):
        partial.pop(key, None)
    ckpt = score_answers(DEFAULT_GOLD, partial)
    assert ckpt["rate"] < PASS_THRESHOLD


def test_scan_pack_dir(tmp_path: Path) -> None:
    (tmp_path / "a.jsonl").write_text('{"ok": true}\n', encoding="utf-8")
    report = scan_pack(tmp_path)
    assert report["ok"] is True
