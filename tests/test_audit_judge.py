from __future__ import annotations

import json
from pathlib import Path

import pytest

from src.ops.audit_judge import (
    AuditFinding,
    AuditJudgeResult,
    JudgedFinding,
    build_cursor_handoff,
    call_judge,
    judge_finding,
    parse_findings_from_markdown,
    run_audit_judge,
)


SAMPLE_FINDINGS_MD = """\
---

## Run a40d72ef-9ca2-4ede-a391-79ccc52f23e9
- status: done
- skill: audit-repo

### Finding 1 - Severity: bug
- File: alfa-ai/deploy/docker-compose.yml:129
- Description: Audit repo mount missing on worker before fix.
- Suggestion: Bind-mount hub clone at /workspace/alfa-ai:ro.

### Finding 2 - Severity: suggestion
- File: alfa-ai/docs/operations/SCHEDULED_AUDIT_MISSIONS.md:90
- Description: Runbook did not document sudo mkdir on hub.
- Suggestion: Add install-agent-audit-logs-dir.sh step.
"""


def test_parse_findings_from_markdown() -> None:
    findings = parse_findings_from_markdown(SAMPLE_FINDINGS_MD)
    assert len(findings) == 2
    assert findings[0].run_id == "a40d72ef-9ca2-4ede-a391-79ccc52f23e9"
    assert findings[0].finding_index == 1
    assert findings[0].severity == "bug"
    assert "docker-compose.yml" in findings[0].file_path
    assert findings[0].fingerprint
    assert findings[1].finding_index == 2


def test_build_cursor_handoff_contains_verdicts() -> None:
    finding = AuditFinding(
        run_id="run-1",
        finding_index=1,
        severity="bug",
        file_path="alfa-ai/deploy/x.yml:1",
        description="Example issue",
        suggestion="Fix it",
        raw_block="raw",
    )
    judged_list = [
        JudgedFinding(
            finding=finding,
            judge=AuditJudgeResult(verdict="confirm", confidence="high"),
        )
    ]
    handoff = build_cursor_handoff(judged_list, date_label="2026-07-12")
    assert "confirm=1" in handoff
    assert "Do not auto-commit" in handoff
    assert "alfa-ai/deploy/x.yml" in handoff


def test_judge_finding_skipped_when_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "0")
    finding = AuditFinding(
        run_id="r1",
        finding_index=1,
        severity="nit",
        file_path="alfa-ai/docs/a.md:1",
        description="nit",
        suggestion="",
        raw_block="### Finding 1",
    )
    result = judge_finding(finding)
    assert result.judge.skipped is True


def test_run_audit_judge_writes_cursor_handoff(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "0")
    today = "2026-07-12"
    findings_path = tmp_path / f"findings-{today}.md"
    findings_path.write_text(SAMPLE_FINDINGS_MD, encoding="utf-8")

    summary = run_audit_judge(tmp_path, date_label=today)
    assert summary["ok"] is True
    assert summary["new_judged"] == 2

    cursor_path = tmp_path / f"cursor-review-{today}.md"
    assert cursor_path.is_file()
    text = cursor_path.read_text(encoding="utf-8")
    assert "Paste into Cursor" in text
    assert "docker-compose.yml" in text

    judged_jsonl = tmp_path / "judged.jsonl"
    assert judged_jsonl.is_file()
    lines = judged_jsonl.read_text(encoding="utf-8").strip().splitlines()
    assert len(lines) == 2
    rec = json.loads(lines[0])
    assert rec["judge_skipped"] is True
    assert "fingerprint" in rec

    summary2 = run_audit_judge(tmp_path, date_label=today)
    assert summary2["new_judged"] == 0


def test_run_audit_judge_mock_enabled(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "1")
    monkeypatch.setenv("ALFA_AI_JUDGE_ON", "research")

    def fake_call_judge(**kwargs):
        return AuditJudgeResult(verdict="reject", confidence="high")

    monkeypatch.setattr("src.ops.audit_judge.call_judge", fake_call_judge)

    today = "2026-07-12"
    (tmp_path / f"findings-{today}.md").write_text(SAMPLE_FINDINGS_MD, encoding="utf-8")
    summary = run_audit_judge(tmp_path, date_label=today)
    assert summary["new_judged"] == 2

    cursor_path = tmp_path / f"cursor-review-{today}.md"
    assert "reject" in cursor_path.read_text(encoding="utf-8")


def test_call_judge_disabled_without_importing_dotenv(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ALFA_AI_JUDGE_ENABLED", "0")
    result = call_judge(subject="x", context="research", claims="y")
    assert result.skipped is True
