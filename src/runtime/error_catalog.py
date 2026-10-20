"""Structured error catalog for learning-loop L0.

Produces errors.jsonl under ALFA_AI_DATA (or configured path). Agents and
exporters append; corrective-analyst groups by fingerprint.
"""

from __future__ import annotations

import hashlib
import json
import re
import uuid
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal

from src.config import alfa_ai_data_dir, get, workspace_root

Severity = Literal["critical", "high", "medium", "low"]
Source = Literal["pytest", "incident", "mission", "lint", "operator", "eval"]

_WS_RE = re.compile(r"\s+")


@dataclass(slots=True)
class ErrorEntry:
    id: str
    source: str
    repo: str
    severity: str
    summary: str
    evidence: list[str] = field(default_factory=list)
    first_seen: str = ""
    count: int = 1
    fingerprint: str = ""
    proposed_action_id: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


def normalize_message(summary: str) -> str:
    text = (summary or "").strip().lower()
    text = _WS_RE.sub(" ", text)
    # Drop volatile hex / UUIDs for stable fingerprints
    text = re.sub(r"\b[0-9a-f]{8,}\b", "<id>", text)
    text = re.sub(r"\b\d{4}-\d{2}-\d{2}[t ][\d:.-]+\b", "<ts>", text)
    return text[:500]


def make_fingerprint(
    *,
    source: str,
    repo: str,
    summary: str,
    evidence: list[str] | None = None,
) -> str:
    parts = [
        (source or "").strip().lower(),
        (repo or "").strip().lower(),
        normalize_message(summary),
    ]
    if evidence:
        parts.append(normalize_message(evidence[0][:200]))
    raw = "|".join(parts)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]


def error_catalog_path() -> Path:
    configured = get("ALFA_AI_ERROR_CATALOG_PATH", "").strip()
    if configured:
        path = Path(configured).expanduser().resolve()
    else:
        path = alfa_ai_data_dir() / "errors.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def new_entry(
    *,
    source: Source | str,
    summary: str,
    repo: str | None = None,
    severity: Severity | str = "medium",
    evidence: list[str] | None = None,
    proposed_action_id: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> ErrorEntry:
    repo_name = (repo or workspace_root().name or "workspace").strip() or "workspace"
    ev = list(evidence or [])
    fp = make_fingerprint(source=str(source), repo=repo_name, summary=summary, evidence=ev)
    return ErrorEntry(
        id=str(uuid.uuid4()),
        source=str(source),
        repo=repo_name,
        severity=str(severity),
        summary=(summary or "").strip()[:2000],
        evidence=ev[:20],
        first_seen=now_iso(),
        count=1,
        fingerprint=fp,
        proposed_action_id=proposed_action_id,
        metadata=dict(metadata or {}),
    )


def append_entry(entry: ErrorEntry, path: Path | None = None) -> ErrorEntry:
    """Append or merge by fingerprint (increment count on match)."""
    catalog = path or error_catalog_path()
    existing = load_entries(catalog)
    for item in existing:
        if item.fingerprint == entry.fingerprint:
            item.count += 1
            item.evidence = _merge_evidence(item.evidence, entry.evidence)
            if entry.metadata:
                item.metadata = {**item.metadata, **entry.metadata}
            _rewrite_all(existing, catalog)
            return item
    existing.append(entry)
    with catalog.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry.to_dict(), ensure_ascii=True) + "\n")
    return entry


def load_entries(path: Path | None = None) -> list[ErrorEntry]:
    catalog = path or error_catalog_path()
    if not catalog.is_file():
        return []
    out: list[ErrorEntry] = []
    for line in catalog.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(raw, dict):
            continue
        out.append(_from_dict(raw))
    return out


def rollup_by_fingerprint(entries: list[ErrorEntry] | None = None) -> list[ErrorEntry]:
    items = entries if entries is not None else load_entries()
    by_fp: dict[str, ErrorEntry] = {}
    for item in items:
        prev = by_fp.get(item.fingerprint)
        if prev is None:
            by_fp[item.fingerprint] = ErrorEntry(
                id=item.id,
                source=item.source,
                repo=item.repo,
                severity=item.severity,
                summary=item.summary,
                evidence=list(item.evidence),
                first_seen=item.first_seen,
                count=item.count,
                fingerprint=item.fingerprint,
                proposed_action_id=item.proposed_action_id,
                metadata=dict(item.metadata),
            )
            continue
        prev.count += item.count
        prev.evidence = _merge_evidence(prev.evidence, item.evidence)
        if _severity_rank(item.severity) > _severity_rank(prev.severity):
            prev.severity = item.severity
    ranked = sorted(
        by_fp.values(),
        key=lambda e: (_severity_rank(e.severity), e.count),
        reverse=True,
    )
    return ranked


def write_rollup_json(path: Path | None = None) -> Path:
    out = path or (alfa_ai_data_dir() / "errors-rollup.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    data = [e.to_dict() for e in rollup_by_fingerprint()]
    out.write_text(json.dumps(data, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    return out


def record_mission_failure(
    *,
    run_id: str,
    task_id: str,
    role: str,
    summary: str,
    repo: str | None = None,
    severity: str = "medium",
) -> ErrorEntry:
    entry = new_entry(
        source="mission",
        summary=summary or f"{role} failed",
        repo=repo,
        severity=severity,
        evidence=[f"run_id={run_id}", f"task_id={task_id}", f"role={role}"],
        metadata={"run_id": run_id, "task_id": task_id, "role": role},
    )
    return append_entry(entry)


def corrective_actions_markdown(entries: list[ErrorEntry] | None = None) -> str:
    """Deterministic skeleton for corrective-analyst (agent may expand)."""
    ranked = rollup_by_fingerprint(entries)
    lines = [
        "# Corrective actions",
        "",
        f"Generated: {now_iso()}",
        f"Unique fingerprints: {len(ranked)}",
        "",
    ]
    if not ranked:
        lines.append("No cataloged errors.")
        lines.append("")
        return "\n".join(lines)

    for i, item in enumerate(ranked[:50], start=1):
        lines.append(f"## Action {i} — {item.severity} (count={item.count})")
        lines.append(f"- **Fingerprint:** `{item.fingerprint}`")
        lines.append(f"- **Repo:** {item.repo}")
        lines.append(f"- **Source:** {item.source}")
        lines.append(f"- **Summary:** {item.summary}")
        if item.evidence:
            lines.append("- **Evidence:**")
            for ev in item.evidence[:5]:
                lines.append(f"  - {ev}")
        lines.append("- **Proposed steps (would take; not applied):**")
        lines.append("  1. Reproduce using evidence paths/commands.")
        lines.append("  2. Implement minimal fix (human gate for mutate).")
        lines.append("  3. **Acceptance:** re-run failing check; fingerprint count stops growing.")
        lines.append("")
    return "\n".join(lines)


def _severity_rank(severity: str) -> int:
    order = {"critical": 4, "high": 3, "medium": 2, "low": 1}
    return order.get((severity or "").lower(), 0)


def _merge_evidence(a: list[str], b: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in list(a) + list(b):
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
        if len(out) >= 20:
            break
    return out


def _from_dict(raw: dict[str, Any]) -> ErrorEntry:
    evidence = raw.get("evidence") or []
    if not isinstance(evidence, list):
        evidence = [str(evidence)]
    meta = raw.get("metadata") or {}
    if not isinstance(meta, dict):
        meta = {}
    return ErrorEntry(
        id=str(raw.get("id") or uuid.uuid4()),
        source=str(raw.get("source") or "operator"),
        repo=str(raw.get("repo") or "workspace"),
        severity=str(raw.get("severity") or "medium"),
        summary=str(raw.get("summary") or ""),
        evidence=[str(x) for x in evidence],
        first_seen=str(raw.get("first_seen") or now_iso()),
        count=int(raw.get("count") or 1),
        fingerprint=str(raw.get("fingerprint") or ""),
        proposed_action_id=raw.get("proposed_action_id"),
        metadata=meta,
    )


def _rewrite_all(entries: list[ErrorEntry], path: Path) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        for item in entries:
            fh.write(json.dumps(item.to_dict(), ensure_ascii=True) + "\n")
    tmp.replace(path)
