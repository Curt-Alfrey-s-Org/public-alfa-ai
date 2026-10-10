"""Sleep Tier A: consolidate memory, rollup errors, export preference packs.

No weight training. Safe to run overnight on brain/pool idle.
Controlled by ALFA_AI_SLEEP_CURATOR_ENABLED for auto schedules; manual
skill=sleep-curator always allowed (operator mission).
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from src.config import (
    alfa_ai_data_dir,
    memory_max_entries,
    memory_max_file_bytes,
    sleep_curator_enabled,
)
from src.runtime.error_catalog import load_entries, rollup_by_fingerprint, write_rollup_json
from src.runtime.memory import (
    _GOAL_RE,
    _SUMMARY_RE,
    _memory_blocks_from_raw,
    _trim_memory_blocks,
    memory_dir,
    memory_path,
)
from src.runtime.preference_export import export_preference_pack, load_feedback_rows

_LESSON_MARKERS = re.compile(
    r"\b(fix(?:ed)?|bug|error|lesson|avoid|never|must|don'?t|do not|prefer|use)\b",
    re.IGNORECASE,
)


@dataclass(slots=True)
class SleepCuratorReport:
    ok: bool
    started_at: str
    finished_at: str = ""
    memory_files_touched: int = 0
    blocks_before: int = 0
    blocks_after: int = 0
    lessons_extracted: int = 0
    error_fingerprints: int = 0
    preference_pairs: int = 0
    paths: dict[str, str] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)
    dry_run: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "memory_files_touched": self.memory_files_touched,
            "blocks_before": self.blocks_before,
            "blocks_after": self.blocks_after,
            "lessons_extracted": self.lessons_extracted,
            "error_fingerprints": self.error_fingerprints,
            "preference_pairs": self.preference_pairs,
            "paths": dict(self.paths),
            "notes": list(self.notes),
            "dry_run": self.dry_run,
        }

    def to_markdown(self) -> str:
        lines = [
            "# Sleep curator report",
            "",
            f"- **OK:** {self.ok}",
            f"- **Started:** {self.started_at}",
            f"- **Finished:** {self.finished_at}",
            f"- **Dry run:** {self.dry_run}",
            f"- **Memory files:** {self.memory_files_touched}",
            f"- **Blocks:** {self.blocks_before} → {self.blocks_after}",
            f"- **Lessons:** {self.lessons_extracted}",
            f"- **Error fingerprints:** {self.error_fingerprints}",
            f"- **Preference pairs:** {self.preference_pairs}",
            "",
            "## Paths",
            "",
        ]
        for k, v in self.paths.items():
            lines.append(f"- **{k}:** `{v}`")
        if self.notes:
            lines.extend(["", "## Notes", ""])
            for n in self.notes:
                lines.append(f"- {n}")
        lines.append("")
        return "\n".join(lines)


def now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


def list_memory_files() -> list[Path]:
    root = memory_dir()
    if not root.is_dir():
        return []
    return sorted(p for p in root.glob("*.md") if p.is_file())


def compact_memory_file(path: Path, *, dry_run: bool = False) -> tuple[int, int, str]:
    """Trim one implement-memory file to entry/byte caps. Returns (before, after, body)."""
    raw = path.read_text(encoding="utf-8") if path.is_file() else ""
    blocks = _memory_blocks_from_raw(raw)
    before = len(blocks)
    body = _trim_memory_blocks(blocks)
    after_blocks = _memory_blocks_from_raw(body)
    after = len(after_blocks)
    if not dry_run and body.strip() != raw.strip():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body + ("\n" if not body.endswith("\n") else ""), encoding="utf-8")
    return before, after, body


def extract_lessons_from_blocks(blocks: list[str], *, max_lessons: int = 40) -> list[dict[str, str]]:
    """Heuristic lessons from mission summaries (no LLM)."""
    lessons: list[dict[str, str]] = []
    for block in reversed(blocks):
        if len(lessons) >= max_lessons:
            break
        goal_m = _GOAL_RE.search(block)
        sum_m = _SUMMARY_RE.search(block)
        if not goal_m or not sum_m:
            continue
        goal = goal_m.group(1).strip()
        summary = sum_m.group(1).strip()
        if not summary:
            continue
        # Prefer blocks that look like corrections / lessons
        score = 1 if _LESSON_MARKERS.search(summary) else 0
        if score == 0 and len(summary) < 40:
            continue
        # One-line distillation
        first = summary.splitlines()[0].strip()[:400]
        lessons.append({"goal": goal[:300], "lesson": first})
    return lessons


def write_lessons_file(lessons: list[dict[str, str]], path: Path | None = None) -> Path:
    out = path or (alfa_ai_data_dir() / "lessons.md")
    out.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# ALFa lessons (sleep curator)",
        "",
        f"Updated: {now_iso()}",
        f"Count: {len(lessons)}",
        "",
        "Heuristic distillations from implement-memory. Review before training.",
        "",
    ]
    for i, item in enumerate(lessons, start=1):
        lines.append(f"## Lesson {i}")
        lines.append(f"- **From goal:** {item.get('goal', '')}")
        lines.append(f"- **Lesson:** {item.get('lesson', '')}")
        lines.append("")
    out.write_text("\n".join(lines), encoding="utf-8")
    return out


def write_morning_digest(report: SleepCuratorReport, path: Path | None = None) -> Path:
    out = path or (alfa_ai_data_dir() / "morning-digest.md")
    out.parent.mkdir(parents=True, exist_ok=True)
    # Append dated section
    section = [
        f"## Digest {report.finished_at or now_iso()}",
        "",
        report.to_markdown(),
        "",
    ]
    prev = out.read_text(encoding="utf-8") if out.is_file() else "# Morning digests\n\n"
    if not prev.startswith("#"):
        prev = "# Morning digests\n\n" + prev
    # Keep last ~20 digests by crude split
    parts = re.split(r"(?=^## Digest )", prev, flags=re.MULTILINE)
    header = parts[0] if parts else "# Morning digests\n\n"
    digests = [p for p in parts[1:] if p.strip()]
    digests.append("\n".join(section))
    digests = digests[-20:]
    out.write_text(header.rstrip() + "\n\n" + "\n".join(digests), encoding="utf-8")
    return out


def run_sleep_curator(
    *,
    dry_run: bool = False,
    require_enabled_flag: bool = False,
    all_memory_files: bool = True,
) -> SleepCuratorReport:
    """Main sleep Tier A pipeline."""
    started = now_iso()
    report = SleepCuratorReport(ok=True, started_at=started, dry_run=dry_run)

    if require_enabled_flag and not sleep_curator_enabled():
        report.ok = False
        report.notes.append("ALFA_AI_SLEEP_CURATOR_ENABLED=0; abort (require_enabled_flag)")
        report.finished_at = now_iso()
        return report

    # 1) Compact implement-memory
    files = list_memory_files() if all_memory_files else [memory_path()]
    files = [p for p in files if p.is_file() or p == memory_path()]
    all_blocks: list[str] = []
    for path in files:
        if not path.is_file():
            continue
        before, after, body = compact_memory_file(path, dry_run=dry_run)
        report.memory_files_touched += 1
        report.blocks_before += before
        report.blocks_after += after
        all_blocks.extend(_memory_blocks_from_raw(body))
        report.paths[f"memory:{path.name}"] = str(path)

    if not files:
        # Ensure dir exists; note empty
        memory_dir()
        report.notes.append("No implement-memory files yet")

    # 2) Lessons
    lessons = extract_lessons_from_blocks(all_blocks)
    report.lessons_extracted = len(lessons)
    if not dry_run:
        lessons_path = write_lessons_file(lessons)
        report.paths["lessons"] = str(lessons_path)
    else:
        report.paths["lessons"] = str(alfa_ai_data_dir() / "lessons.md")
        report.notes.append("dry_run: skipped writing lessons.md")

    # 3) Error rollup
    entries = load_entries()
    ranked = rollup_by_fingerprint(entries)
    report.error_fingerprints = len(ranked)
    if not dry_run:
        rollup_path = write_rollup_json()
        report.paths["errors_rollup"] = str(rollup_path)
    else:
        report.paths["errors_rollup"] = str(alfa_ai_data_dir() / "errors-rollup.json")

    # 4) Preference pack
    try:
        if dry_run:
            pairs = len(load_feedback_rows())
            report.preference_pairs = pairs  # not true pairs; note
            report.notes.append(
                f"dry_run: feedback inbox rows={pairs}; export skipped"
            )
            report.paths["preference_pack"] = str(
                alfa_ai_data_dir() / "preference-pack.jsonl"
            )
        else:
            pref = export_preference_pack()
            report.preference_pairs = int(pref.get("pairs") or 0)
            report.paths["preference_pack"] = str(pref.get("path") or "")
            report.paths["feedback_inbox"] = str(pref.get("inbox") or "")
    except OSError as exc:
        report.notes.append(f"preference export failed: {exc}")

    # 5) Caps note
    report.notes.append(
        f"memory caps: max_entries={memory_max_entries()} max_bytes={memory_max_file_bytes()}"
    )

    report.finished_at = now_iso()

    # 6) Morning digest
    if not dry_run:
        digest_path = write_morning_digest(report)
        report.paths["morning_digest"] = str(digest_path)

    # Machine-readable last report
    if not dry_run:
        last = alfa_ai_data_dir() / "sleep-curator-last.json"
        last.write_text(
            json.dumps(report.to_dict(), ensure_ascii=True, indent=2) + "\n",
            encoding="utf-8",
        )
        report.paths["last_report"] = str(last)

    return report
