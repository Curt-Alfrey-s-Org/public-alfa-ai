from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from src.llm.client import ChatTurn
from src.llm.draft_guide import (
    MAX_LOG_TEXT_CHARS,
    run_draft_guide_loop,
    sanitize_secret_text,
)
from src.llm.judge import JudgeIssue, JudgeResult


def _path_b_ready(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "1")
    monkeypatch.setenv("ALFA_AI_JUDGE_ON", "research")
    monkeypatch.delenv("ALFA_AI_JUDGE_API_BASE", raising=False)
    monkeypatch.setenv("LLAMACPP_7B_URL", "http://127.0.0.1:8470/v1")
    monkeypatch.setattr(
        "src.llm.draft_guide.path_b_sim_dump_guardrail",
        lambda settings=None: (False, "test default: no auto-write"),
    )


def _turn(content: str, *, model: str = "alfa-coder-draft") -> ChatTurn:
    return ChatTurn(content=content, model=model)


def _judge_result(verdict: str, *, guidance: str = "") -> JudgeResult:
    return JudgeResult(
        verdict=verdict,  # type: ignore[arg-type]
        confidence="medium",
        issues=[JudgeIssue(severity="medium", claim="example", reason="needs work")]
        if verdict == "revise"
        else [],
        guidance=guidance,
        raw=json.dumps({"verdict": verdict, "confidence": "medium", "guidance": guidance}),
        model="frontier-code",
        safe_to_auto_apply=False,
    )


def test_skipped_when_judge_disabled(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "0")
    log_path = tmp_path / "sessions.jsonl"

    result = run_draft_guide_loop("write a helper", log_path=log_path)

    assert result.skipped is True
    assert result.enabled is False
    assert result.safe_to_auto_apply is False
    assert result.rounds == 0
    assert not log_path.exists()


def test_skipped_when_judge_on_excludes_research(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _path_b_ready(monkeypatch)
    monkeypatch.setenv("ALFA_AI_JUDGE_ON", "run_command")
    log_path = tmp_path / "sessions.jsonl"

    result = run_draft_guide_loop("write a helper", log_path=log_path)

    assert result.skipped is True
    assert "not in ALFA_AI_JUDGE_ON" in result.skip_reason
    assert not log_path.exists()


def test_skipped_when_path_a_api_base_set(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _path_b_ready(monkeypatch)
    monkeypatch.setenv("ALFA_AI_JUDGE_API_BASE", "http://127.0.0.1:11434/v1")
    log_path = tmp_path / "sessions.jsonl"

    result = run_draft_guide_loop("write a helper", log_path=log_path)

    assert result.skipped is True
    assert "ALFA_AI_JUDGE_API_BASE" in result.skip_reason
    assert not log_path.exists()


def test_skipped_when_7b_url_unset(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _path_b_ready(monkeypatch)
    monkeypatch.delenv("LLAMACPP_7B_URL", raising=False)
    log_path = tmp_path / "sessions.jsonl"

    result = run_draft_guide_loop("write a helper", log_path=log_path)

    assert result.skipped is True
    assert "LLAMACPP_7B_URL" in result.skip_reason
    assert not log_path.exists()


def test_confirm_on_first_round(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _path_b_ready(monkeypatch)

    def fake_draft(messages, **kwargs):
        assert kwargs.get("model") == "alfa-coder-draft"
        return _turn("draft answer v1")

    def fake_judge(**kwargs):
        assert kwargs["context"] == "research"
        assert kwargs["claims"] == "draft answer v1"
        assert kwargs.get("model") == "frontier-code"
        assert kwargs.get("litellm_only") is True
        return _judge_result("confirm")

    monkeypatch.setattr("src.llm.draft_guide.get_completion_turn", fake_draft)
    monkeypatch.setattr("src.llm.draft_guide.run_judge", fake_judge)

    log_path = tmp_path / "sessions.jsonl"
    result = run_draft_guide_loop("summarize inference", log_path=log_path)

    assert result.skipped is False
    assert result.verdict == "confirm"
    assert result.final_draft == "draft answer v1"
    assert result.rounds == 1
    assert result.safe_to_auto_apply is False
    assert result.project_auto_applied is False

    lines = log_path.read_text(encoding="utf-8").strip().splitlines()
    assert len(lines) == 3
    draft_row = json.loads(lines[0])
    judge_row = json.loads(lines[1])
    decision_row = json.loads(lines[2])
    assert draft_row["role"] == "7b_draft"
    assert draft_row["session_id"]
    assert draft_row["round"] == 1
    assert draft_row["model"] == "alfa-coder-draft"
    assert draft_row["text"] == "draft answer v1"
    assert re.match(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", draft_row["utc"])
    assert judge_row["role"] == "27b_judge"
    assert judge_row["verdict"] == "confirm"
    assert judge_row["session_id"] == draft_row["session_id"]
    assert decision_row["role"] == "decision"
    assert decision_row["decision"] == "confirmed"
    assert decision_row["project_auto_applied"] is False


def test_revise_then_confirm(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _path_b_ready(monkeypatch)

    drafts = iter(["draft v1", "draft v2 improved"])
    verdicts = iter(["revise", "confirm"])

    def fake_draft(messages, **kwargs):
        text = next(drafts)
        if text == "draft v2 improved":
            user = messages[-1]["content"]
            assert "Judge revision guidance" in user
            assert "add tests" in user
        return _turn(text)

    def fake_judge(**kwargs):
        verdict = next(verdicts)
        return _judge_result(verdict, guidance="add tests")

    monkeypatch.setattr("src.llm.draft_guide.get_completion_turn", fake_draft)
    monkeypatch.setattr("src.llm.draft_guide.run_judge", fake_judge)

    log_path = tmp_path / "sessions.jsonl"
    result = run_draft_guide_loop("fix module", log_path=log_path)

    assert result.verdict == "confirm"
    assert result.final_draft == "draft v2 improved"
    assert result.rounds == 2
    assert result.safe_to_auto_apply is False
    assert len(log_path.read_text(encoding="utf-8").strip().splitlines()) == 5
    rows = [json.loads(line) for line in log_path.read_text(encoding="utf-8").strip().splitlines()]
    assert [r["role"] for r in rows] == [
        "7b_draft",
        "27b_judge",
        "7b_revise",
        "27b_judge",
        "decision",
    ]
    assert rows[1]["guidance"] == "add tests"


def test_stops_on_reject(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _path_b_ready(monkeypatch)

    calls = {"draft": 0, "judge": 0}

    def fake_draft(messages, **kwargs):
        calls["draft"] += 1
        return _turn("unsafe draft")

    def fake_judge(**kwargs):
        calls["judge"] += 1
        return _judge_result("reject")

    monkeypatch.setattr("src.llm.draft_guide.get_completion_turn", fake_draft)
    monkeypatch.setattr("src.llm.draft_guide.run_judge", fake_judge)

    result = run_draft_guide_loop("dangerous task", log_path=tmp_path / "sessions.jsonl")

    assert result.verdict == "reject"
    assert calls["draft"] == 1
    assert calls["judge"] == 1
    assert result.safe_to_auto_apply is False
    rows = [
        json.loads(line)
        for line in (tmp_path / "sessions.jsonl").read_text(encoding="utf-8").strip().splitlines()
    ]
    assert rows[-1]["role"] == "decision"
    assert rows[-1]["decision"] == "rejected"


def test_max_three_rounds(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _path_b_ready(monkeypatch)

    draft_calls = 0

    def fake_draft(messages, **kwargs):
        nonlocal draft_calls
        draft_calls += 1
        return _turn(f"draft attempt {draft_calls}")

    def fake_judge(**kwargs):
        return _judge_result("revise", guidance="keep revising")

    monkeypatch.setattr("src.llm.draft_guide.get_completion_turn", fake_draft)
    monkeypatch.setattr("src.llm.draft_guide.run_judge", fake_judge)

    result = run_draft_guide_loop("never good enough", max_rounds=10, log_path=tmp_path / "s.jsonl")

    assert draft_calls == 3
    assert result.rounds == 3
    assert result.verdict == "revise"
    assert result.safe_to_auto_apply is False
    rows = [
        json.loads(line)
        for line in (tmp_path / "s.jsonl").read_text(encoding="utf-8").strip().splitlines()
    ]
    assert rows[-1]["decision"] == "max_rounds"


def test_creates_log_parent_dirs(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _path_b_ready(monkeypatch)
    monkeypatch.setattr(
        "src.llm.draft_guide.get_completion_turn",
        lambda messages, **kwargs: _turn("ok"),
    )
    monkeypatch.setattr(
        "src.llm.draft_guide.run_judge",
        lambda **kwargs: _judge_result("confirm"),
    )

    log_path = tmp_path / "nested" / "draft-judge" / "sessions.jsonl"
    run_draft_guide_loop("task", log_path=log_path)

    assert log_path.is_file()


def test_skips_inference_served_draft(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _path_b_ready(monkeypatch)
    monkeypatch.setattr(
        "src.llm.draft_guide.get_completion_turn",
        lambda messages, **kwargs: _turn("oops 27b", model="frontier-code"),
    )
    log_path = tmp_path / "sessions.jsonl"
    result = run_draft_guide_loop("task", log_path=log_path)
    assert result.skipped is True
    assert "inference" in result.skip_reason
    assert not log_path.exists()


def test_sanitize_secret_text_redacts_and_truncates() -> None:
    pem = (
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        "abc\n"
        "-----END OPENSSH PRIVATE KEY-----"
    )
    redacted = sanitize_secret_text(f"token: supersecret {pem} Bearer abcdefghijklmnop")
    assert "supersecret" not in redacted
    assert "BEGIN OPENSSH" not in redacted
    assert "abcdefghijklmnop" not in redacted
    assert "[REDACTED]" in redacted

    huge = "a" * (MAX_LOG_TEXT_CHARS + 50)
    truncated = sanitize_secret_text(huge)
    assert truncated.endswith("...")
    assert len(truncated) == MAX_LOG_TEXT_CHARS + 3


def test_jsonl_redacts_secrets_in_draft(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _path_b_ready(monkeypatch)
    monkeypatch.setattr(
        "src.llm.draft_guide.get_completion_turn",
        lambda messages, **kwargs: _turn("use api_key=sk-secretvalue here"),
    )
    monkeypatch.setattr(
        "src.llm.draft_guide.run_judge",
        lambda **kwargs: _judge_result("confirm"),
    )
    log_path = tmp_path / "sessions.jsonl"
    run_draft_guide_loop("task", log_path=log_path)
    text = log_path.read_text(encoding="utf-8")
    assert "sk-secretvalue" not in text
    assert "[REDACTED]" in text


def test_confirm_auto_writes_sandbox_when_sim_dump_ok(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _path_b_ready(monkeypatch)
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setattr(
        "src.llm.draft_guide.path_b_sim_dump_guardrail",
        lambda settings=None: (True, "sim dump allowlist only"),
    )
    monkeypatch.setattr(
        "src.llm.draft_guide.get_completion_turn",
        lambda messages, **kwargs: _turn("draft answer v1"),
    )
    monkeypatch.setattr(
        "src.llm.draft_guide.run_judge",
        lambda **kwargs: _judge_result("confirm"),
    )
    log_path = tmp_path / "sessions.jsonl"
    result = run_draft_guide_loop("summarize inference", log_path=log_path)

    assert result.safe_to_auto_apply is False
    assert result.project_auto_applied is True
    assert result.autonomy_reason == "sim dump allowlist only"
    applied = Path(result.applied_path)
    assert applied.is_file()
    assert applied.parent == (tmp_path / "draft-judge" / "applied").resolve()
    body = applied.read_text(encoding="utf-8")
    assert "draft answer v1" in body
    assert "summarize inference" in body
    decision = json.loads(log_path.read_text(encoding="utf-8").strip().splitlines()[-1])
    assert decision["project_auto_applied"] is True
    assert decision["applied_path"] == result.applied_path


def test_confirm_skips_write_when_guardrail_fails(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _path_b_ready(monkeypatch)
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setattr(
        "src.llm.draft_guide.path_b_sim_dump_guardrail",
        lambda settings=None: (False, "dump allowlist includes non-sim loads"),
    )
    monkeypatch.setattr(
        "src.llm.draft_guide.get_completion_turn",
        lambda messages, **kwargs: _turn("draft answer v1"),
    )
    monkeypatch.setattr(
        "src.llm.draft_guide.run_judge",
        lambda **kwargs: _judge_result("confirm"),
    )
    result = run_draft_guide_loop("task", log_path=tmp_path / "sessions.jsonl")
    assert result.project_auto_applied is False
    assert result.applied_path == ""
    assert "non-sim" in result.autonomy_reason
    assert not (tmp_path / "draft-judge" / "applied").exists()


def test_applied_file_redacts_secrets(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    from src.llm.draft_guide import write_confirmed_project_draft

    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    path = write_confirmed_project_draft(
        session_id="12345678-1234-1234-1234-123456789abc",
        task="demo",
        draft="use api_key=sk-secretvalue here",
    )
    body = Path(path).read_text(encoding="utf-8")
    assert "sk-secretvalue" not in body
    assert "[REDACTED]" in body


def test_write_confirmed_rejects_invalid_session(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from src.llm.draft_guide import write_confirmed_project_draft

    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    with pytest.raises(ValueError, match="invalid session_id"):
        write_confirmed_project_draft(session_id="../escape", task="t", draft="d")


def test_confirm_pauses_write_when_live_allowlist_has_real_plug(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    from src.ops.solar_dump import path_b_sim_dump_guardrail as real_guardrail

    _path_b_ready(monkeypatch)
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setattr("src.llm.draft_guide.path_b_sim_dump_guardrail", real_guardrail)
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_enabled", lambda: True)
    monkeypatch.setattr("src.ops.solar_dump.home_assistant_ready", lambda: True)
    monkeypatch.setattr(
        "src.llm.draft_guide.get_completion_turn",
        lambda messages, **kwargs: _turn("draft answer v1"),
    )
    monkeypatch.setattr(
        "src.llm.draft_guide.run_judge",
        lambda **kwargs: _judge_result("confirm"),
    )
    result = run_draft_guide_loop(
        "task",
        log_path=tmp_path / "sessions.jsonl",
        settings={"ha_switch_allowlist": "switch.living_room_lamp"},
    )
    assert result.safe_to_auto_apply is False
    assert result.project_auto_applied is False
    assert result.applied_path == ""
    assert "non-sim" in result.autonomy_reason
    assert not (tmp_path / "draft-judge" / "applied").exists()
