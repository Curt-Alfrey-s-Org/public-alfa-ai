"""Tests for Missions findings inbox (severity + would_take_action)."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

from src.ops.mission_fleet import build_findings_inbox
from src.runtime.artifacts import audit_report_body


SAMPLE_FINDINGS = """\
---

## Run a40d72ef-9ca2-4ede-a391-79ccc52f23e9
- status: done
- skill: audit-repo

### Finding 1 - Severity: bug
- File: alfa-ai/deploy/docker-compose.yml:129
- Description: Audit repo mount missing on worker.
- Suggestion: Bind-mount hub clone at /workspace/alfa-ai:ro.

### Finding 2 - Severity: nit
- File: alfa-ai/docs/x.md:1
- Description: Minor docs typo.
- Suggestion: Fix typo in heading.
"""


def test_build_findings_inbox_sorts_by_severity(tmp_path: Path) -> None:
    today = datetime.now(tz=UTC).strftime("%Y-%m-%d")
    (tmp_path / f"findings-{today}.md").write_text(SAMPLE_FINDINGS, encoding="utf-8")
    inbox = build_findings_inbox(tmp_path)
    assert inbox["ok"] is True
    assert inbox["structured_count"] == 2
    assert inbox["count"] == 2
    assert inbox["findings"][0]["severity"] == "bug"
    assert inbox["findings"][1]["severity"] == "nit"
    assert "Bind-mount" in inbox["findings"][0]["would_take_action"]
    assert inbox["findings"][0]["would_auto_apply"] is False


def test_build_findings_inbox_pipeline_gaps_when_no_finding_blocks(
    tmp_path: Path,
) -> None:
    today = datetime.now(tz=UTC).strftime("%Y-%m-%d")
    (tmp_path / f"findings-{today}.md").write_text(
        "## Run 51baa78d-5fb2-4626-8208-2ed27cafcaa3\n"
        "- status: done\n"
        "_No artifact text exported (run may have failed early)._\n",
        encoding="utf-8",
    )
    (tmp_path / "findings.jsonl").write_text(
        json.dumps(
            {
                "run_id": "51baa78d-5fb2-4626-8208-2ed27cafcaa3",
                "status": "done",
                "target_host": "102",
                "goal": "Audit host 102",
                "artifact_count": 0,
            }
        )
        + "\n",
        encoding="utf-8",
    )
    inbox = build_findings_inbox(tmp_path)
    assert inbox["structured_count"] == 0
    assert inbox["count"] >= 1
    row = inbox["findings"][0]
    assert row["source"] == "pipeline_gap"
    assert row["severity"] == "high"
    assert "would_take_action" in row
    assert row["would_auto_apply"] is False


def test_audit_report_body_requires_finding_blocks() -> None:
    body = audit_report_body("Audit deploy", "Looked at compose.")
    assert "### Finding N - Severity:" in body
    assert "propose only" in body.lower() or "Suggestion:" in body


def test_pipeline_gap_excludes_stale_jsonl_rows(tmp_path: Path) -> None:
    """Old failed jsonl rows must not appear when they are not from today (UTC)."""
    today = datetime.now(tz=UTC).strftime("%Y-%m-%d")
    stale_run = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    today_run = "51baa78d-5fb2-4626-8208-2ed27cafcaa3"
    (tmp_path / "findings.jsonl").write_text(
        json.dumps(
            {
                "run_id": stale_run,
                "status": "failed",
                "target_host": "111",
                "goal": "smoke test contracts file run",
                "artifact_count": 0,
                "exported_at": "2025-07-15T12:00:00+00:00",
                "markdown_path": str(tmp_path / "findings-2025-07-15.md"),
            }
        )
        + "\n"
        + json.dumps(
            {
                "run_id": today_run,
                "status": "done",
                "target_host": "102",
                "goal": "Audit host 102",
                "artifact_count": 0,
                "exported_at": datetime.now(tz=UTC).isoformat(),
            }
        )
        + "\n",
        encoding="utf-8",
    )
    inbox = build_findings_inbox(tmp_path)
    assert inbox["structured_count"] == 0
    gap_rows = [r for r in inbox["findings"] if r.get("source") == "pipeline_gap"]
    assert len(gap_rows) == 1
    assert gap_rows[0]["run_id"] == today_run
    assert stale_run not in {r.get("run_id") for r in inbox["findings"]}


def test_pipeline_gap_empty_when_no_today_signals(tmp_path: Path) -> None:
    """No today md and only stale jsonl without date signals -> empty inbox."""
    (tmp_path / "findings.jsonl").write_text(
        json.dumps(
            {
                "run_id": "deadbeef-dead-beef-dead-beefdeadbeef",
                "status": "failed",
                "target_host": "111",
                "goal": "smoke test contracts file run",
                "artifact_count": 0,
            }
        )
        + "\n",
        encoding="utf-8",
    )
    inbox = build_findings_inbox(tmp_path)
    assert inbox["count"] == 0
    assert inbox["findings"] == []
