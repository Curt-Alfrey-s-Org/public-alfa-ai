"""Parse structured review.md / review agent output into JSON issues."""

from __future__ import annotations

import re
from typing import Any

_ISSUE_HEADER = re.compile(
    r"^###\s*Issue\s*\d+\s*[—\-–]\s*Severity:\s*(bug|suggestion|nit)\s*$",
    re.IGNORECASE | re.MULTILINE,
)
_FIELD = re.compile(
    r"^-\s*(File|Description|Suggestion|Status):\s*(.+)$",
    re.IGNORECASE | re.MULTILINE,
)
_FILE_LINE = re.compile(r"^(?P<path>.+?)(?::(?P<line>\d+))?$")


def parse_review_issues(text: str, *, max_issues: int = 50) -> list[dict[str, Any]]:
    """Extract issues from reviewer markdown. Empty list if none found."""
    if not (text or "").strip():
        return []
    limit = max(1, min(int(max_issues), 100))
    issues: list[dict[str, Any]] = []

    # Split on issue headers
    parts = _ISSUE_HEADER.split(text)
    # parts: [preamble, sev1, body1, sev2, body2, ...] when using split with groups
    # re.split with capturing groups includes separators
    headers = list(_ISSUE_HEADER.finditer(text))
    if not headers:
        # Fallback: loose "Severity: bug" bullets
        return _loose_parse(text, limit)

    for i, match in enumerate(headers):
        severity = match.group(1).lower()
        start = match.end()
        end = headers[i + 1].start() if i + 1 < len(headers) else len(text)
        body = text[start:end]
        issue = _fields_from_body(body, severity=severity)
        if issue.get("description") or issue.get("file"):
            issues.append(issue)
        if len(issues) >= limit:
            break
    return issues


def _fields_from_body(body: str, *, severity: str) -> dict[str, Any]:
    fields: dict[str, str] = {}
    for m in _FIELD.finditer(body):
        key = m.group(1).lower()
        fields[key] = m.group(2).strip()
    file_raw = fields.get("file", "")
    path = ""
    line: int | None = None
    fm = _FILE_LINE.match(file_raw)
    if fm:
        path = (fm.group("path") or "").strip()
        if fm.group("line"):
            try:
                line = int(fm.group("line"))
            except ValueError:
                line = None
    status = (fields.get("status") or "open").lower()
    if status not in ("open", "fixed", "wontfix"):
        status = "open"
    return {
        "severity": severity if severity in ("bug", "suggestion", "nit") else "suggestion",
        "file": path,
        "line": line,
        "description": fields.get("description", ""),
        "suggestion": fields.get("suggestion", ""),
        "status": status,
    }


def _loose_parse(text: str, limit: int) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    for m in re.finditer(
        r"severity\s*[:=]\s*(bug|suggestion|nit)",
        text,
        re.IGNORECASE,
    ):
        issues.append(
            {
                "severity": m.group(1).lower(),
                "file": "",
                "line": None,
                "description": text[m.end() : m.end() + 200].strip().split("\n")[0][:500],
                "suggestion": "",
                "status": "open",
            }
        )
        if len(issues) >= limit:
            break
    return issues
