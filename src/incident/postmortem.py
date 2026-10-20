"""Blameless postmortem export from incident timeline."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from src.api.models.incident import IncidentEventRecord, IncidentRecord, IncidentRemediationRecord


def build_postmortem_markdown(
    incident: IncidentRecord,
    events: list[IncidentEventRecord],
    proposals: list[IncidentRemediationRecord],
) -> str:
    """Render a markdown postmortem template pre-filled from incident data."""
    now = datetime.now(tz=UTC).strftime("%Y-%m-%d %H:%M UTC")
    lines: list[str] = [
        f"# Postmortem: {incident.alertname}",
        "",
        f"**Incident ID:** `{incident.id}`  ",
        f"**Status:** {incident.status}  ",
        f"**Severity:** {incident.severity}  ",
        f"**Opened:** {incident.opened_at}  ",
        f"**Resolved:** {incident.resolved_at or 'n/a'}  ",
        f"**Generated:** {now}",
        "",
        "## Summary",
        "",
        incident.summary or incident.annotations.get("summary") or "_TBD_",
        "",
        "## Impact",
        "",
        "- _User-visible impact:_ TBD",
        "- _Duration:_ TBD",
        "- _Blast radius:_ TBD",
        "",
        "## Timeline",
        "",
    ]
    for event in events:
        lines.append(f"- **{event.created_at}** `{event.event_type}`")
        payload = event.payload or {}
        if payload:
            summary_bits = []
            for key in ("summary", "reason", "message", "classification", "confidence"):
                if key in payload and payload[key]:
                    summary_bits.append(f"{key}={payload[key]}")
            if summary_bits:
                lines.append(f"  - {'; '.join(summary_bits)}")
    lines.extend(
        [
            "",
            "## Root cause",
            "",
        ]
    )
    latest = proposals[0] if proposals else None
    if latest and latest.root_cause:
        lines.append(latest.root_cause)
    else:
        lines.append("_TBD_")
    lines.extend(
        [
            "",
            "## What went well",
            "",
            "- Programmatic investigate steps completed before human review",
            "",
            "## What went wrong",
            "",
            "- _TBD_",
            "",
            "## Action items",
            "",
            "| Owner | Action | Priority |",
            "|-------|--------|----------|",
            "| ops | Verify monitoring rule thresholds | P2 |",
            "",
            "## Lessons learned",
            "",
            "- _TBD_",
            "",
        ]
    )
    runbook = incident.annotations.get("runbook_url") or incident.labels.get("runbook_url")
    if runbook:
        lines.extend(["## Runbook", "", f"- {runbook}", ""])
    return "\n".join(lines)
