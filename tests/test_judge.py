from __future__ import annotations

import json

import pytest

from src.llm.judge import parse_judge_response, run_judge, should_run_judge


def test_parse_judge_json() -> None:
    raw = json.dumps(
        {
            "verdict": "reject",
            "confidence": "high",
            "issues": [{"severity": "high", "claim": "rm -rf", "reason": "destructive"}],
            "missing_evidence": [],
            "safe_to_auto_apply": True,
        }
    )
    result = parse_judge_response(raw)
    assert result.verdict == "reject"
    assert result.safe_to_auto_apply is False  # hard policy
    assert len(result.issues) == 1


def test_parse_judge_guidance() -> None:
    raw = json.dumps(
        {
            "verdict": "revise",
            "confidence": "medium",
            "issues": [],
            "missing_evidence": [],
            "guidance": "cite FastAPI docs",
            "safe_to_auto_apply": False,
        }
    )
    result = parse_judge_response(raw)
    assert result.guidance == "cite FastAPI docs"


def test_parse_judge_fence() -> None:
    raw = '```json\n{"verdict":"confirm","confidence":"medium","issues":[],"missing_evidence":[],"safe_to_auto_apply":false}\n```'
    result = parse_judge_response(raw)
    assert result.verdict == "confirm"


def test_judge_disabled_skips(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "0")
    result = run_judge(subject="test", context="run_command", claims="ls")
    assert result.skipped is True
    assert result.enabled is False
    assert result.safe_to_auto_apply is False


def test_should_run_judge(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "1")
    monkeypatch.setenv("ALFA_AI_JUDGE_ON", "run_command,research")
    assert should_run_judge("run_command") is True
    assert should_run_judge("freeform") is False


def test_judge_call_failure_revise(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "1")
    monkeypatch.setenv("ALFA_AI_JUDGE_ON", "all")
    monkeypatch.setenv("ALFA_AI_JUDGE_API_BASE", "")
    monkeypatch.delenv("ALFA_AI_JUDGE_API_BASE", raising=False)

    def boom(*args, **kwargs):
        raise RuntimeError("no backend")

    monkeypatch.setattr("src.llm.judge.get_completion", boom)
    result = run_judge(subject="x", context="all", claims="y")
    assert result.verdict == "revise"
    assert result.safe_to_auto_apply is False
