"""Agent fleet catalog and Admin Missions summaries."""

from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal

from src.ops.mission_heartbeat import audit_log_dir, read_heartbeat

FleetKind = Literal["skill", "side_process", "worker_host"]
HeartbeatUiStatus = Literal["alive", "idle", "stale", "unknown"]

# Runs with many tool calls but no artifacts/findings are flagged for operator review.
IDLE_BURN_TOOL_THRESHOLD = 10

_STALE_SEC: dict[str, int] = {
    "day-session": 3600,
    "day-session-feeder": 5400,
    "export-findings": 1200,
    "judge-findings": 1200,
}


@dataclass(frozen=True, slots=True)
class FleetEntry:
    id: str
    label: str
    kind: FleetKind
    skill: str = ""
    process_name: str = ""
    description: str = ""
    artifact_hints: str = ""


FLEET_CATALOG: tuple[FleetEntry, ...] = (
    FleetEntry(
        id="audit-repo",
        label="Audit repo",
        kind="skill",
        skill="audit-repo",
        description="Read-only deploy/docs/security audits via orchestrator missions.",
        artifact_hints=".alfa_ai/artifacts/{run_id}/",
    ),
    FleetEntry(
        id="error-cataloger",
        label="Error cataloger",
        kind="skill",
        skill="error-cataloger",
        description="Roll up mission and incident errors into errors.jsonl.",
        artifact_hints=".alfa_ai/errors.jsonl",
    ),
    FleetEntry(
        id="corrective-analyst",
        label="Corrective analyst",
        kind="skill",
        skill="corrective-analyst",
        description="Propose corrective actions from the error catalog.",
        artifact_hints="mission artifacts",
    ),
    FleetEntry(
        id="sleep-curator",
        label="Sleep curator",
        kind="skill",
        skill="sleep-curator",
        description="Tier-A nightly memory curation (learning loop).",
        artifact_hints="curator artifacts",
    ),
    FleetEntry(
        id="host-facts",
        label="Host facts",
        kind="skill",
        skill="host-facts",
        description="Local processes, docker, disk/mem, allowlisted log grep.",
        artifact_hints="host-facts.md",
    ),
    FleetEntry(
        id="day-session",
        label="Day session",
        kind="side_process",
        process_name="run_audit_day_session.sh",
        description="Host loop: feeder + export + judge until STOP file.",
        artifact_hints="agent-audit-logs/session.log",
    ),
    FleetEntry(
        id="day-session-feeder",
        label="Mission feeder",
        kind="side_process",
        process_name="audit_mission_feeder.sh",
        description="Enqueues read-only audit missions when active runs below max.",
        artifact_hints="agent-audit-logs/feeder.log",
    ),
    FleetEntry(
        id="export-findings",
        label="Export findings",
        kind="side_process",
        process_name="export_audit_findings.py",
        description="Exports completed runs to hub findings markdown/jsonl.",
        artifact_hints="findings-YYYY-MM-DD.md",
    ),
    FleetEntry(
        id="judge-findings",
        label="Judge findings",
        kind="side_process",
        process_name="judge_audit_findings.py",
        description="Dual-check exported findings; writes cursor-review handoff.",
        artifact_hints="judged.jsonl, cursor-review-*.md",
    ),
)


# (host_id, label, live_enabled)
WORKER_HOST_IDS: tuple[tuple[str, str, bool], ...] = (
    ("111", "Brain hub", True),
    ("105", "Apps host", True),
    ("102", "Market VM", True),
    ("103", "ATEMS VM", True),
    ("106", "ProBilliards", True),
    ("107", "Monitoring", True),
    ("148", "AI edge/RAG", True),
    ("100", "ALFA-AI VM", True),
    ("93", "WOLF1 Windows", False),
    ("59", "gaming_worker_c (stub)", False),
    ("219", "gaming_worker_a (stub)", False),
    ("249", "gaming-worker-b (stub)", False),
)

_WORKER_STALE_SEC = 180


def enabled_mission_hosts() -> tuple[tuple[str, str], ...]:
    """Worker hosts that accept mission_enqueue target_host (live fleet)."""
    return tuple((host_id, label) for host_id, label, enabled in WORKER_HOST_IDS if enabled)


def enabled_mission_host_ids() -> frozenset[str]:
    return frozenset(host_id for host_id, _, enabled in WORKER_HOST_IDS if enabled)


def mission_host_label(host_id: str) -> str:
    for hid, label, _ in WORKER_HOST_IDS:
        if hid == host_id:
            return label
    return host_id


def format_enabled_mission_hosts() -> str:
    return ", ".join(f".{h} ({label})" for h, label in enabled_mission_hosts())


def validate_mission_target_host(raw: str) -> str:
    """Normalize and ensure target_host is an enabled worker (not gaming stubs)."""
    from src.runtime.worker_host import normalize_worker_host

    host = normalize_worker_host(raw)
    if host in enabled_mission_host_ids():
        return host
    for hid, label, enabled in WORKER_HOST_IDS:
        if hid == host:
            if not enabled:
                raise ValueError(
                    f"Host .{host} ({label}) is not enabled for missions yet. "
                    f"Enabled: {format_enabled_mission_hosts()}"
                )
            break
    raise ValueError(
        f"Unknown mission target host .{host}. Enabled: {format_enabled_mission_hosts()}"
    )


def _worker_heartbeat_status(host_id: str) -> dict[str, Any]:
    try:
        from src.api.redis_heartbeat import get_worker_heartbeat

        hb = get_worker_heartbeat(f"alfa-ai-worker-{host_id}")
    except Exception:
        hb = None
    if not hb:
        return {
            "heartbeat_status": "unknown",
            "last_heartbeat_at": None,
            "last_action": None,
            "heartbeat_age_sec": None,
        }
    extra = hb.get("extra") if isinstance(hb.get("extra"), dict) else {}
    received = str(hb.get("received_at") or "")
    updated = _parse_iso(received)
    status = str(extra.get("status") or "alive")
    ui = classify_heartbeat(
        {"status": status, "updated_at": received},
        stale_sec=_WORKER_STALE_SEC,
    )
    age = None
    if updated:
        age = int((datetime.now(tz=UTC) - updated).total_seconds())
    return {
        "heartbeat_status": ui,
        "last_heartbeat_at": received or None,
        "last_action": str(extra.get("last_action") or ""),
        "heartbeat_age_sec": age,
    }


def _worker_host_fleet_rows() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for host_id, label, enabled in WORKER_HOST_IDS:
        hb = _worker_heartbeat_status(host_id)
        rows.append(
            {
                "id": f"worker-{host_id}",
                "label": label,
                "kind": "worker_host",
                "skill": "",
                "process_name": "alfa-ai-worker",
                "description": f"Agent worker on host {host_id} (enabled={enabled})",
                "artifact_hints": "orchestrator runs + host-facts.md",
                "host_id": host_id,
                "enabled": enabled,
                "active_run_count": 0,
                "done_run_count": 0,
                **hb,
            }
        )
    return rows


def _parse_iso(ts: str) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def classify_heartbeat(
    hb: dict[str, Any] | None,
    *,
    stale_sec: int,
    now: datetime | None = None,
) -> HeartbeatUiStatus:
    if hb is None:
        return "unknown"
    raw_status = str(hb.get("status") or "").strip().lower()
    if raw_status == "idle":
        return "idle"
    updated = _parse_iso(str(hb.get("updated_at") or ""))
    if updated is None:
        return "unknown"
    ref = now or datetime.now(tz=UTC)
    age = (ref - updated).total_seconds()
    if age <= stale_sec:
        return "alive"
    return "stale"


def _run_skill(run: dict[str, Any], tasks: list[dict[str, Any]] | None = None) -> str:
    skill = str(run.get("skill") or "").strip()
    if skill:
        return skill
    if tasks:
        for task in tasks:
            meta = task.get("metadata")
            if isinstance(meta, dict):
                s = str(meta.get("skill") or "").strip()
                if s:
                    return s
    return ""


def count_runs_by_skill(runs: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    """Return per-skill active (pending/running) and done counts."""
    counts: dict[str, dict[str, int]] = {}
    for run in runs:
        skill = _run_skill(run)
        if not skill:
            continue
        bucket = counts.setdefault(skill, {"active": 0, "done": 0})
        status = str(run.get("status") or "")
        if status in ("pending", "running"):
            bucket["active"] += 1
        elif status == "done":
            bucket["done"] += 1
    return counts


def count_finding_blocks(text: str) -> int:
    return len(re.findall(r"^### Finding\b", text, flags=re.MULTILINE))


def compute_usefulness(
    *,
    run_status: str,
    artifact_count: int,
    tool_event_count: int,
    finding_count: int = 0,
) -> dict[str, Any]:
    likely_idle_burn = (
        run_status == "done"
        and finding_count == 0
        and artifact_count == 0
        and tool_event_count >= IDLE_BURN_TOOL_THRESHOLD
    )
    return {
        "tool_event_count": tool_event_count,
        "artifact_count": artifact_count,
        "finding_count": finding_count,
        "likely_idle_burn": likely_idle_burn,
        "idle_burn_tool_threshold": IDLE_BURN_TOOL_THRESHOLD,
    }


def build_fleet_response(
    runs: list[dict[str, Any]],
    log_dir: Path | None = None,
) -> dict[str, Any]:
    """Merge catalog, heartbeats, and run counts for GET /missions/fleet."""
    root = log_dir or audit_log_dir()
    skill_counts = count_runs_by_skill(runs)
    entries: list[dict[str, Any]] = []

    for item in FLEET_CATALOG:
        row: dict[str, Any] = {
            "id": item.id,
            "label": item.label,
            "kind": item.kind,
            "skill": item.skill,
            "process_name": item.process_name,
            "description": item.description,
            "artifact_hints": item.artifact_hints,
        }
        if item.kind == "skill" and item.skill:
            stats = skill_counts.get(item.skill, {"active": 0, "done": 0})
            row["active_run_count"] = stats["active"]
            row["done_run_count"] = stats["done"]
            row["heartbeat_status"] = "unknown"
            row["last_heartbeat_at"] = None
            row["last_action"] = None
            row["heartbeat_age_sec"] = None
        else:
            hb = read_heartbeat(root, item.id)
            stale = _STALE_SEC.get(item.id, 3600)
            ui_status = classify_heartbeat(hb, stale_sec=stale)
            row["heartbeat_status"] = ui_status
            row["active_run_count"] = 0
            row["done_run_count"] = 0
            if hb:
                row["last_heartbeat_at"] = hb.get("updated_at")
                row["last_action"] = hb.get("last_action")
                updated = _parse_iso(str(hb.get("updated_at") or ""))
                if updated:
                    row["heartbeat_age_sec"] = int(
                        (datetime.now(tz=UTC) - updated).total_seconds()
                    )
            else:
                row["last_heartbeat_at"] = None
                row["last_action"] = None
                row["heartbeat_age_sec"] = None
        entries.append(row)

    entries.extend(_worker_host_fleet_rows())

    return {
        "ok": True,
        "log_dir": str(root),
        "log_dir_accessible": root.is_dir(),
        "catalog_count": len(entries),
        "fleet": entries,
    }


_SEVERITY_RANK: dict[str, int] = {
    "critical": 0,
    "high": 1,
    "bug": 1,
    "medium": 2,
    "suggestion": 2,
    "low": 3,
    "nit": 3,
    "unknown": 4,
    "info": 4,
}

_EMPTY_WORKSPACE_HINTS = (
    "repository appears empty",
    "repo is empty",
    "empty results",
    "glob_files",
    "not mounted",
    "inaccessible",
    "no artifact text exported",
)


def _severity_rank(severity: str) -> int:
    return _SEVERITY_RANK.get((severity or "").strip().lower(), 4)


def _load_judged_by_fingerprint(log_dir: Path) -> dict[str, dict[str, Any]]:
    path = log_dir / "judged.jsonl"
    out: dict[str, dict[str, Any]] = {}
    if not path.is_file():
        return out
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except (json.JSONDecodeError, TypeError):
                continue
            if not isinstance(row, dict):
                continue
            fp = str(row.get("fingerprint") or "")
            if fp:
                out[fp] = row
    except OSError:
        pass
    return out


def _default_would_take(severity: str, description: str) -> str:
    desc = (description or "").lower()
    if "empty" in desc or "not mounted" in desc or "no artifact" in desc:
        return (
            "Restart alfa-ai-worker on the target host; confirm ALFA_AI_AUDIT_ROOTS "
            "bind-mounts; clear stuck running runs; re-enqueue audit-repo."
        )
    if severity in ("bug", "high", "critical"):
        return (
            "Operator review required: verify evidence paths, then open an implement "
            "mission only after Approve (L2). No auto-fix."
        )
    return "Operator review; dismiss or schedule a follow-up audit. No auto-fix (L1)."


def _finding_row_from_parsed(
    finding: Any,
    judged: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    suggestion = str(getattr(finding, "suggestion", "") or "").strip()
    severity = str(getattr(finding, "severity", "") or "unknown").lower()
    fingerprint = str(getattr(finding, "fingerprint", "") or "")
    j = judged.get(fingerprint) or {}
    would = suggestion or _default_would_take(
        severity, str(getattr(finding, "description", "") or "")
    )
    return {
        "id": fingerprint or f"{getattr(finding, 'run_id', '')}:{getattr(finding, 'finding_index', 0)}",
        "source": "audit_finding",
        "run_id": str(getattr(finding, "run_id", "") or ""),
        "finding_index": int(getattr(finding, "finding_index", 0) or 0),
        "severity": severity,
        "file": str(getattr(finding, "file_path", "") or ""),
        "description": str(getattr(finding, "description", "") or "")[:2000],
        "suggestion": suggestion[:2000],
        "would_take_action": would[:2000],
        "would_auto_apply": False,
        "judge_verdict": j.get("judge_verdict"),
        "judge_confidence": j.get("judge_confidence"),
        "judge_skipped": bool(j.get("judge_skipped")) if j else None,
    }


def _pipeline_gap_record_is_today(
    rec: dict[str, Any],
    today: str,
    md_text: str,
) -> bool:
    """True when a findings.jsonl row belongs to today (UTC).

    See docs/ADMIN_MISSIONS.md (pipeline-gap date filter).
    """
    exported_at = str(rec.get("exported_at") or "").strip()
    if exported_at:
        parsed = _parse_iso(exported_at)
        if parsed is not None:
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=UTC)
            else:
                parsed = parsed.astimezone(UTC)
            if parsed.strftime("%Y-%m-%d") == today:
                return True

    markdown_path = str(rec.get("markdown_path") or "").strip()
    if markdown_path and Path(markdown_path).name == f"findings-{today}.md":
        return True

    run_id = str(rec.get("run_id") or "").strip()
    if run_id and md_text and run_id.lower() in md_text:
        return True

    return False


def _pipeline_gap_findings(log_dir: Path, today: str) -> list[dict[str, Any]]:
    """Turn empty/failed exports into operator-visible inbox rows (today UTC only)."""
    rows: list[dict[str, Any]] = []
    jsonl = log_dir / "findings.jsonl"
    md_path = log_dir / f"findings-{today}.md"
    md_text = ""
    if md_path.is_file():
        try:
            md_text = md_path.read_text(encoding="utf-8", errors="replace").lower()
        except OSError:
            md_text = ""

    seen_runs: set[str] = set()
    if jsonl.is_file():
        try:
            for line in jsonl.read_text(encoding="utf-8", errors="replace").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(rec, dict):
                    continue
                if not _pipeline_gap_record_is_today(rec, today, md_text):
                    continue
                run_id = str(rec.get("run_id") or "")
                if not run_id or run_id in seen_runs:
                    continue
                status = str(rec.get("status") or "")
                artifact_count = int(rec.get("artifact_count") or 0)
                goal = str(rec.get("goal") or "")[:200]
                target = str(rec.get("target_host") or "111")
                gap = False
                severity = "medium"
                description = ""
                would = ""
                if status == "failed":
                    gap = True
                    severity = "high"
                    description = (
                        f"Mission failed on host .{target}: {goal or '(no goal)'}"
                    )
                    would = (
                        f"Inspect run {run_id[:8]}... in Missions; fix worker on "
                        f".{target}; re-enqueue after worker heartbeat is alive."
                    )
                elif artifact_count == 0:
                    gap = True
                    severity = "high"
                    description = (
                        f"Run completed with no exportable artifact text "
                        f"(host .{target}): {goal or '(no goal)'}"
                    )
                    would = (
                        f"Ensure alfa-ai-worker-{target} is running with "
                        "ALFA_AI_AUDIT_ROOTS mounted; then re-run audit-repo."
                    )
                if gap:
                    seen_runs.add(run_id)
                    rows.append(
                        {
                            "id": f"gap:{run_id}",
                            "source": "pipeline_gap",
                            "run_id": run_id,
                            "finding_index": 0,
                            "severity": severity,
                            "file": f"host.{target}",
                            "description": description,
                            "suggestion": would,
                            "would_take_action": would,
                            "would_auto_apply": False,
                            "judge_verdict": None,
                            "judge_confidence": None,
                            "judge_skipped": None,
                        }
                    )
        except OSError:
            pass

    if md_text and any(h in md_text for h in _EMPTY_WORKSPACE_HINTS):
        if not any(r.get("source") == "pipeline_gap" for r in rows):
            rows.append(
                {
                    "id": f"gap:empty-workspace:{today}",
                    "source": "pipeline_gap",
                    "run_id": "",
                    "finding_index": 0,
                    "severity": "high",
                    "file": "ALFA_AI_AUDIT_ROOTS",
                    "description": (
                        "Exported audit text indicates empty or unmounted workspace "
                        "(glob/grep returned nothing)."
                    ),
                    "suggestion": (
                        "Bind-mount repo roots into alfa-ai-worker; set "
                        "ALFA_AI_AUDIT_ROOTS; restart worker; re-enqueue audit."
                    ),
                    "would_take_action": (
                        "Bind-mount repo roots into alfa-ai-worker; set "
                        "ALFA_AI_AUDIT_ROOTS; restart worker; re-enqueue audit."
                    ),
                    "would_auto_apply": False,
                    "judge_verdict": None,
                    "judge_confidence": None,
                    "judge_skipped": None,
                }
            )
    return rows


def build_findings_inbox(log_dir: Path | None = None) -> dict[str, Any]:
    """Severity-sorted findings for Admin Missions (propose-only would_take_action)."""
    from src.ops.audit_judge import parse_findings_from_markdown

    root = log_dir or audit_log_dir()
    today = datetime.now(tz=UTC).strftime("%Y-%m-%d")
    findings_md = root / f"findings-{today}.md"
    items: list[dict[str, Any]] = []
    judged = _load_judged_by_fingerprint(root) if root.is_dir() else {}

    if findings_md.is_file():
        try:
            text = findings_md.read_text(encoding="utf-8", errors="replace")
            for finding in parse_findings_from_markdown(text):
                items.append(_finding_row_from_parsed(finding, judged))
        except OSError:
            pass

    structured_count = len(items)
    # Pipeline gaps only when structured Finding blocks are missing.
    if structured_count == 0 and root.is_dir():
        items.extend(_pipeline_gap_findings(root, today))
        if findings_md.is_file() and not items:
            items.append(
                {
                    "id": f"gap:no-structured:{today}",
                    "source": "pipeline_gap",
                    "run_id": "",
                    "finding_index": 0,
                    "severity": "medium",
                    "file": str(findings_md.name),
                    "description": (
                        "Hub export exists but contains no ### Finding N - Severity: "
                        "blocks for the judge/UI to triage."
                    ),
                    "suggestion": (
                        "Restart workers with AUDIT_ROOTS mounted; re-enqueue "
                        "audit-repo so reports emit structured findings."
                    ),
                    "would_take_action": (
                        "Restart workers with AUDIT_ROOTS mounted; re-enqueue "
                        "audit-repo so reports emit structured findings."
                    ),
                    "would_auto_apply": False,
                    "judge_verdict": None,
                    "judge_confidence": None,
                    "judge_skipped": None,
                }
            )

    items.sort(
        key=lambda row: (
            _severity_rank(str(row.get("severity") or "")),
            str(row.get("run_id") or ""),
            int(row.get("finding_index") or 0),
        )
    )

    by_severity: dict[str, int] = {}
    for row in items:
        sev = str(row.get("severity") or "unknown")
        by_severity[sev] = by_severity.get(sev, 0) + 1

    return {
        "ok": True,
        "date": today,
        "log_dir": str(root),
        "log_dir_accessible": root.is_dir(),
        "count": len(items),
        "structured_count": structured_count,
        "by_severity": by_severity,
        "findings": items,
        "note": (
            "would_take_action is propose-only (L1). Nothing is auto-applied."
        ),
    }


def build_artifacts_summary(log_dir: Path | None = None) -> dict[str, Any]:
    """Summarize today's hub audit outputs for Admin Missions."""
    root = log_dir or audit_log_dir()
    today = datetime.now(tz=UTC).strftime("%Y-%m-%d")

    findings_md = root / f"findings-{today}.md"
    judged_md = root / f"judged-findings-{today}.md"
    judged_jsonl = root / "judged.jsonl"
    cursor_review = root / f"cursor-review-{today}.md"

    finding_count = 0
    if findings_md.is_file():
        try:
            finding_count = count_finding_blocks(
                findings_md.read_text(encoding="utf-8", errors="replace")
            )
        except OSError:
            pass

    judged_count = 0
    if judged_jsonl.is_file():
        try:
            for line in judged_jsonl.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.strip():
                    judged_count += 1
        except OSError:
            pass

    export_hb = read_heartbeat(root, "export-findings")
    judge_hb = read_heartbeat(root, "judge-findings")
    inbox = build_findings_inbox(root)

    return {
        "ok": True,
        "date": today,
        "log_dir": str(root),
        "log_dir_accessible": root.is_dir(),
        "finding_count": finding_count,
        "inbox_count": inbox.get("count", 0),
        "by_severity": inbox.get("by_severity") or {},
        "judged_count": judged_count,
        "paths": {
            "findings_md": str(findings_md) if findings_md.is_file() else None,
            "judged_md": str(judged_md) if judged_md.is_file() else None,
            "judged_jsonl": str(judged_jsonl) if judged_jsonl.is_file() else None,
            "cursor_review_md": str(cursor_review) if cursor_review.is_file() else None,
        },
        "last_export_at": (export_hb or {}).get("updated_at"),
        "last_judge_at": (judge_hb or {}).get("updated_at"),
        "last_export_action": (export_hb or {}).get("last_action"),
        "last_judge_action": (judge_hb or {}).get("last_action"),
    }


def build_all_workers_status() -> dict[str, Any]:
    """Per-host worker liveness from Redis heartbeats."""
    workers = _worker_host_fleet_rows()
    live = [w for w in workers if w.get("enabled")]
    unknown = sum(1 for w in live if w.get("heartbeat_status") == "unknown")
    return {
        "ok": True,
        "workers": workers,
        "live_host_count": len(live),
        "unknown_count": unknown,
    }


def build_worker_status(runs: list[dict[str, Any]], tasks_by_run: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    """Infer alfa-ai-worker liveness from orchestrator running work."""
    running_runs = [r for r in runs if str(r.get("status")) == "running"]
    running_tasks: list[dict[str, Any]] = []
    for run in runs:
        run_id = str(run.get("run_id") or "")
        for task in tasks_by_run.get(run_id, []):
            if str(task.get("status")) == "running":
                running_tasks.append(task)

    if running_tasks:
        t = running_tasks[0]
        return {
            "ok": True,
            "status": "busy",
            "detail": "Task running in orchestrator store.",
            "active_run_count": len(running_runs),
            "running_task_id": t.get("task_id"),
            "running_run_id": t.get("run_id"),
        }
    if running_runs:
        return {
            "ok": True,
            "status": "busy",
            "detail": "Run marked running.",
            "active_run_count": len(running_runs),
            "running_task_id": None,
            "running_run_id": running_runs[0].get("run_id"),
        }
    pending = sum(1 for r in runs if str(r.get("status")) == "pending")
    if pending:
        return {
            "ok": True,
            "status": "idle",
            "detail": f"{pending} pending run(s); worker may be polling.",
            "active_run_count": 0,
            "pending_run_count": pending,
        }
    return {
        "ok": True,
        "status": "unknown",
        "detail": "No running tasks and no pending runs in store.",
        "active_run_count": 0,
        "hosts": build_all_workers_status().get("workers", []),
    }


def catalog_as_dicts() -> list[dict[str, Any]]:
    return [asdict(entry) for entry in FLEET_CATALOG]


def build_missions_chat_context(
    runs: list[dict[str, Any]] | None = None,
    log_dir: Path | None = None,
) -> dict[str, Any]:
    """Compact mission fleet snapshot for Ask ALFa context (missions_fleet section)."""
    root = log_dir or audit_log_dir()
    tasks_by_run: dict[str, list[dict[str, Any]]] = {}
    if runs is None:
        try:
            from src.runtime.factory import build_orchestrator
            from src.runtime.store import run_to_dict, task_to_dict

            orch = build_orchestrator()
            runs = [run_to_dict(r) for r in orch.store.list_runs()]
            for run in runs:
                rid = str(run.get("run_id") or "")
                if not rid:
                    continue
                tasks_by_run[rid] = [
                    task_to_dict(t) for t in orch.store.list_tasks_for_run(rid)
                ]
        except Exception:
            runs = []

    from src.ops.mission_wedge import detect_mission_wedge, enrich_run_from_tasks

    runs = [
        enrich_run_from_tasks(r, tasks_by_run.get(str(r.get("run_id") or "")) or [])
        for r in runs
    ]

    fleet = build_fleet_response(runs, root)
    artifacts = build_artifacts_summary(root)
    pause_path = root / "FEEDER_PAUSE"
    active = [r for r in runs if str(r.get("status")) in ("pending", "running")]
    recent = sorted(
        runs,
        key=lambda r: str(r.get("created_at") or ""),
        reverse=True,
    )[:8]
    wedge = detect_mission_wedge(
        runs, tasks_by_run=tasks_by_run, log_dir=root
    )

    fleet_rows: list[dict[str, Any]] = []
    for row in fleet.get("fleet") or []:
        fleet_rows.append(
            {
                "id": row.get("id"),
                "label": row.get("label"),
                "kind": row.get("kind"),
                "heartbeat_status": row.get("heartbeat_status"),
                "active_run_count": row.get("active_run_count"),
                "done_run_count": row.get("done_run_count"),
                "last_action": row.get("last_action"),
            }
        )

    worker_rows = [r for r in fleet.get("fleet") or [] if r.get("kind") == "worker_host"]
    enabled_workers = [
        {
            "host": row.get("host_id"),
            "label": row.get("label"),
            "enabled": row.get("enabled"),
            "heartbeat_status": row.get("heartbeat_status"),
            "last_action": row.get("last_action"),
        }
        for row in worker_rows
    ]

    return {
        "enabled_target_hosts": [
            {"host": h, "label": label} for h, label in enabled_mission_hosts()
        ],
        "workers": enabled_workers,
        "feeder_paused": pause_path.is_file(),
        "feeder_pause_path": str(pause_path),
        "log_dir_accessible": root.is_dir(),
        "active_run_count": len(active),
        "active_runs": [
            {
                "run_id": r.get("run_id"),
                "goal": (str(r.get("goal") or ""))[:120],
                "status": r.get("status"),
                "skill": r.get("skill"),
                "target_host": r.get("target_host"),
                "created_at": r.get("created_at"),
                "updated_at": r.get("updated_at"),
            }
            for r in active[:6]
        ],
        "recent_runs": [
            {
                "run_id": r.get("run_id"),
                "goal": (str(r.get("goal") or ""))[:80],
                "status": r.get("status"),
                "skill": r.get("skill"),
                "target_host": r.get("target_host"),
                "created_at": r.get("created_at"),
                "updated_at": r.get("updated_at"),
            }
            for r in recent
        ],
        "fleet": fleet_rows,
        "artifacts_today": {
            "date": artifacts.get("date"),
            "finding_count": artifacts.get("finding_count"),
            "inbox_count": artifacts.get("inbox_count"),
            "by_severity": artifacts.get("by_severity"),
            "judged_count": artifacts.get("judged_count"),
            "last_export_at": artifacts.get("last_export_at"),
            "last_judge_at": artifacts.get("last_judge_at"),
        },
        "top_findings": (build_findings_inbox(root).get("findings") or [])[:8],
        "wedge": wedge,
    }


_MISSION_RUN_ID_RE = re.compile(
    r"run_id=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
    re.IGNORECASE,
)


def build_mission_navigation_hint(
    run_id: str,
    *,
    target_host: str,
    skill: str = "",
) -> dict[str, Any]:
    """Post-approve guidance for mission_enqueue (Ask ALFa + Missions tab deep link)."""
    short = run_id[:8] if len(run_id) >= 8 else run_id
    label = mission_host_label(target_host)
    return {
        "run_id": run_id,
        "target_host": target_host,
        "target_label": label,
        "skill": skill,
        "missions_path": f"/admin/missions?run={run_id}",
        "summary": (
            f"Mission queued on worker .{target_host} ({label}). "
            f"Open Missions and select run {short}... for live tool output."
        ),
        "steps": [
            "Click Open Missions below (or Admin -> Missions in the top nav).",
            f"Select the run for host .{target_host} ({short}...) in the left list.",
            "Watch Live tool events in the center panel while the worker runs.",
            "When status is done, review Artifacts and today's hub findings export.",
        ],
    }


def mission_navigation_from_stdout(
    stdout: str,
    params: dict[str, Any] | None,
) -> dict[str, Any] | None:
    match = _MISSION_RUN_ID_RE.search(stdout or "")
    if not match:
        return None
    p = params or {}
    return build_mission_navigation_hint(
        match.group(1),
        target_host=str(p.get("target_host") or "111"),
        skill=str(p.get("skill") or ""),
    )
