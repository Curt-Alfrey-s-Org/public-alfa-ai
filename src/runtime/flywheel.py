"""Data flywheel MAPE orchestrator (Monitor, Analyze, Plan, Execute staging).

Tier A (this module): monitor signals, run sleep curator, export train pack.
Tier B execute (GPU QLoRA, LoRA promote) is operator-only — see
docs/operations/DATA_FLYWHEEL_OPERATOR.md.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from src.config import alfa_ai_data_dir, get
from src.runtime.error_catalog import load_entries, rollup_by_fingerprint
from src.runtime.preference_export import load_feedback_rows, pairs_from_feedback
from src.runtime.sleep_curator import run_sleep_curator
from src.runtime.train_export import export_train_pack


def flywheel_enabled() -> bool:
    return get("ALFA_AI_FLYWHEEL_ENABLED", "0").strip() in ("1", "true", "yes", "on")


def flywheel_root() -> Path:
    root = alfa_ai_data_dir() / "flywheel"
    root.mkdir(parents=True, exist_ok=True)
    return root


@dataclass(slots=True)
class FlywheelPhaseReport:
    phase: str
    ok: bool
    summary: str = ""
    details: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "phase": self.phase,
            "ok": self.ok,
            "summary": self.summary,
            "details": dict(self.details),
        }


@dataclass(slots=True)
class FlywheelReport:
    ok: bool
    started_at: str
    finished_at: str = ""
    phases: list[FlywheelPhaseReport] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    dry_run: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "phases": [p.to_dict() for p in self.phases],
            "notes": list(self.notes),
            "dry_run": self.dry_run,
        }


def _monitor_phase() -> FlywheelPhaseReport:
    errors = load_entries()
    ranked = rollup_by_fingerprint(errors)
    feedback_rows = load_feedback_rows()
    pairs = pairs_from_feedback()
    top = ranked[:5]
    summary = (
        f"errors={len(errors)} fingerprints={len(ranked)} "
        f"feedback_rows={len(feedback_rows)} preference_pairs={len(pairs)}"
    )
    return FlywheelPhaseReport(
        phase="monitor",
        ok=True,
        summary=summary,
        details={
            "error_count": len(errors),
            "fingerprint_count": len(ranked),
            "feedback_rows": len(feedback_rows),
            "preference_pairs": len(pairs),
            "top_fingerprints": [
                {
                    "fingerprint": item.fingerprint,
                    "count": item.count,
                    "severity": item.severity,
                    "summary": item.summary[:200],
                }
                for item in top
            ],
        },
    )


def run_data_flywheel(
    *,
    dry_run: bool = False,
    skip_curator: bool = False,
    skip_export: bool = False,
) -> FlywheelReport:
    """Run MAPE Tier A: monitor, analyze (curator), plan (train export)."""
    started = datetime.now(tz=UTC)
    report = FlywheelReport(
        ok=True,
        started_at=started.isoformat(),
        dry_run=dry_run,
    )

    try:
        monitor = _monitor_phase()
        report.phases.append(monitor)
    except OSError as exc:
        report.ok = False
        report.phases.append(
            FlywheelPhaseReport(
                phase="monitor",
                ok=False,
                summary=str(exc),
            )
        )
        report.finished_at = datetime.now(tz=UTC).isoformat()
        _persist_report(report)
        return report

    if not skip_curator and not dry_run:
        try:
            curator = run_sleep_curator(dry_run=False)
            report.phases.append(
                FlywheelPhaseReport(
                    phase="analyze",
                    ok=bool(curator.ok),
                    summary=(
                        f"memory {curator.blocks_before}->{curator.blocks_after} "
                        f"lessons={curator.lessons_extracted} "
                        f"prefs={curator.preference_pairs}"
                    ),
                    details=curator.to_dict(),
                )
            )
            if not curator.ok:
                report.ok = False
        except OSError as exc:
            report.ok = False
            report.phases.append(
                FlywheelPhaseReport(
                    phase="analyze",
                    ok=False,
                    summary=str(exc),
                )
            )
    elif skip_curator:
        report.phases.append(
            FlywheelPhaseReport(
                phase="analyze",
                ok=True,
                summary="skipped (--skip-curator)",
            )
        )
    else:
        report.phases.append(
            FlywheelPhaseReport(
                phase="analyze",
                ok=True,
                summary="skipped (dry-run)",
            )
        )

    if not skip_export and not dry_run:
        try:
            export = export_train_pack()
            report.phases.append(
                FlywheelPhaseReport(
                    phase="plan",
                    ok=bool(export.ok),
                    summary=f"export_dir={export.export_dir}",
                    details=export.to_dict(),
                )
            )
            if not export.ok:
                report.ok = False
            report.notes.append(
                "Tier B staging: run publish_train_pack_to_hub.sh on hub host "
                "(learning_loop_tier_a.sh includes publish unless --skip-publish)"
            )
        except OSError as exc:
            report.ok = False
            report.phases.append(
                FlywheelPhaseReport(
                    phase="plan",
                    ok=False,
                    summary=str(exc),
                )
            )
    elif skip_export:
        report.phases.append(
            FlywheelPhaseReport(
                phase="plan",
                ok=True,
                summary="skipped (--skip-export)",
            )
        )
    else:
        report.phases.append(
            FlywheelPhaseReport(
                phase="plan",
                ok=True,
                summary="skipped (dry-run)",
            )
        )

    report.phases.append(
        FlywheelPhaseReport(
            phase="execute",
            ok=True,
            summary="deferred (operator Tier B: alfa-train + LoRA promote)",
            details={"automated": False, "doc": "docs/operations/LORA_ADAPTER_OPERATOR.md"},
        )
    )

    report.finished_at = datetime.now(tz=UTC).isoformat()
    _persist_report(report)
    return report


def _persist_report(report: FlywheelReport) -> None:
    root = flywheel_root()
    ts = datetime.now(tz=UTC).strftime("%Y%m%dT%H%M%SZ")
    path = root / f"flywheel-{ts}.json"
    path.write_text(
        json.dumps(report.to_dict(), indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    (root / "LATEST.txt").write_text(str(path) + "\n", encoding="utf-8")
