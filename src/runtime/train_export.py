"""Export sleep-hour training packs for alfa-train (learning-loop L3 / Tier B).

Does not train. Stages JSONL + MANIFEST under ALFA_AI_DATA/train-export/
(or configured path) for hub copy → trainer island.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from src.config import alfa_ai_data_dir, get, workspace_root
from src.runtime.error_catalog import load_entries, rollup_by_fingerprint
from src.runtime.preference_export import (
    export_preference_pack,
    load_feedback_rows,
    pairs_from_feedback,
    preference_export_path,
)


MANIFEST_SCHEMA_VERSION = "1"
scan_pass_TOOL = "scripts/scan_pass_jsonl.py"


def train_base_model_target() -> str:
    return get("ALFA_AI_TRAIN_BASE_MODEL", "qwen3.6-27b").strip() or "qwen3.6-27b"


def resolve_git_sha() -> str:
    configured = get("ALFA_AI_GIT_SHA", "").strip()
    if configured:
        return configured
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(workspace_root()),
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except OSError:
        pass
    return ""


def patch_manifest_scan_pass(manifest_path: Path, scan_report: dict[str, Any]) -> None:
    """Merge scan_pass results into MANIFEST after publish (hub copy)."""
    data: dict[str, Any] = {}
    if manifest_path.is_file():
        try:
            data = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            data = {}
    data["scan_pass"] = {
        "ok": bool(scan_report.get("ok")),
        "tool": scan_pass_TOOL,
        "hit_count": int(scan_report.get("hit_count") or 0),
        "scanned_at": datetime.now(tz=UTC).isoformat(),
    }
    manifest_path.write_text(
        json.dumps(data, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def train_export_root() -> Path:
    configured = get("ALFA_AI_TRAIN_EXPORT_PATH", "").strip()
    if configured:
        path = Path(configured).expanduser().resolve()
    else:
        path = alfa_ai_data_dir() / "train-export"
    path.mkdir(parents=True, exist_ok=True)
    return path


def hub_staging_hint() -> str:
    """Documented hub path for operators (not auto-mounted here)."""
    return get(
        "ALFA_AI_TRAIN_HUB_HINT",
        "/mnt/hub/alfa-ai/training/alfa-train/datasets/from-alfa-ai",
    ).strip()


@dataclass(slots=True)
class TrainExportReport:
    ok: bool
    export_dir: str
    files: dict[str, str] = field(default_factory=dict)
    counts: dict[str, int] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)
    hub_hint: str = ""
    created_at: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "export_dir": self.export_dir,
            "files": dict(self.files),
            "counts": dict(self.counts),
            "notes": list(self.notes),
            "hub_hint": self.hub_hint,
            "created_at": self.created_at,
        }


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def lessons_to_chat_jsonl(lessons_path: Path, out_path: Path) -> int:
    """Convert lessons.md heuristic bullets to chat SFT rows."""
    if not lessons_path.is_file():
        out_path.write_text("", encoding="utf-8")
        return 0
    text = lessons_path.read_text(encoding="utf-8")
    n = 0
    with out_path.open("w", encoding="utf-8") as fh:
        current_goal = ""
        current_lesson = ""
        for line in text.splitlines():
            if line.startswith("- **From goal:**"):
                current_goal = line.split(":", 1)[-1].strip()
            elif line.startswith("- **Lesson:**"):
                current_lesson = line.split(":", 1)[-1].strip()
                if current_goal and current_lesson:
                    row = {
                        "messages": [
                            {
                                "role": "user",
                                "content": (
                                    f"What should we remember from this ALFa work?\n"
                                    f"Goal context: {current_goal}"
                                ),
                            },
                            {"role": "assistant", "content": current_lesson},
                        ],
                        "source": "sleep_lessons",
                    }
                    fh.write(json.dumps(row, ensure_ascii=True) + "\n")
                    n += 1
                    current_goal = ""
                    current_lesson = ""
    return n


def preference_to_dpo_jsonl(pref_path: Path, out_path: Path) -> int:
    """Map preference-pack rows to TRL/Axolotl-style preference pairs."""
    if not pref_path.is_file():
        out_path.write_text("", encoding="utf-8")
        return 0
    n = 0
    with pref_path.open(encoding="utf-8") as src, out_path.open("w", encoding="utf-8") as dst:
        for line in src:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            prompt = str(row.get("prompt") or "").strip()
            chosen = str(row.get("chosen") or "").strip()
            rejected = str(row.get("rejected") or "").strip()
            if not prompt or not chosen or not rejected:
                continue
            # Common DPO / preference formats
            out = {
                "prompt": prompt,
                "chosen": chosen,
                "rejected": rejected,
                # Axolotl / some trainers use these aliases
                "chosen_response": chosen,
                "rejected_response": rejected,
                "source": row.get("source") or "alfa-ai-preference",
            }
            dst.write(json.dumps(out, ensure_ascii=True) + "\n")
            n += 1
    return n


def error_catalog_to_fix_chat_jsonl(out_path: Path) -> int:
    """Turn high-count error fingerprints into 'how to fix' chat seeds (operator review)."""
    ranked = rollup_by_fingerprint(load_entries())
    n = 0
    with out_path.open("w", encoding="utf-8") as fh:
        for item in ranked[:100]:
            if item.count < 1:
                continue
            user = (
                f"We keep seeing this error in ALFa (count={item.count}, "
                f"severity={item.severity}, source={item.source}):\n{item.summary}"
            )
            evidence = "\n".join(item.evidence[:5]) if item.evidence else "(no evidence)"
            assistant = (
                f"Investigate fingerprint `{item.fingerprint}` in repo `{item.repo}`. "
                f"Evidence:\n{evidence}\n"
                "Reproduce, apply a minimal fix, re-run the failing check, "
                "and confirm the fingerprint count stops growing. Human gate before mutate."
            )
            row = {
                "messages": [
                    {"role": "user", "content": user},
                    {"role": "assistant", "content": assistant},
                ],
                "source": "error_catalog",
                "fingerprint": item.fingerprint,
            }
            fh.write(json.dumps(row, ensure_ascii=True) + "\n")
            n += 1
    return n


def export_train_pack(*, run_preference_export: bool = True) -> TrainExportReport:
    """Build a dated train-export directory for hub / alfa-train ingest."""
    ts = datetime.now(tz=UTC).strftime("%Y%m%dT%H%M%SZ")
    root = train_export_root() / ts
    root.mkdir(parents=True, exist_ok=True)
    report = TrainExportReport(
        ok=True,
        export_dir=str(root),
        hub_hint=hub_staging_hint(),
        created_at=datetime.now(tz=UTC).isoformat(),
    )

    # Refresh preference pack from feedback inbox
    if run_preference_export:
        try:
            pref_report = export_preference_pack()
            report.counts["preference_pairs"] = int(pref_report.get("pairs") or 0)
            report.notes.append(f"preference export: {pref_report.get('path')}")
        except OSError as exc:
            report.notes.append(f"preference export skipped: {exc}")

    pref_src = preference_export_path()
    pref_dst = root / "preference-pack.jsonl"
    if pref_src.is_file():
        shutil.copy2(pref_src, pref_dst)
        report.files["preference_pack"] = str(pref_dst)
    else:
        pref_dst.write_text("", encoding="utf-8")
        report.files["preference_pack"] = str(pref_dst)
        report.notes.append("preference-pack empty (no pairs yet)")

    dpo_path = root / "preference-dpo.jsonl"
    report.counts["dpo_rows"] = preference_to_dpo_jsonl(pref_dst, dpo_path)
    report.files["preference_dpo"] = str(dpo_path)

    lessons_src = alfa_ai_data_dir() / "lessons.md"
    lessons_dst = root / "lessons.md"
    if lessons_src.is_file():
        shutil.copy2(lessons_src, lessons_dst)
    else:
        lessons_dst.write_text("# No lessons yet\n", encoding="utf-8")
    report.files["lessons"] = str(lessons_dst)

    chat_lessons = root / "lessons-chat-sft.jsonl"
    report.counts["lesson_chat_rows"] = lessons_to_chat_jsonl(lessons_dst, chat_lessons)
    report.files["lessons_chat_sft"] = str(chat_lessons)

    fix_chat = root / "error-fix-chat-sft.jsonl"
    report.counts["error_fix_rows"] = error_catalog_to_fix_chat_jsonl(fix_chat)
    report.files["error_fix_chat_sft"] = str(fix_chat)

    # Pointers for operators
    readme = root / "README.md"
    readme.write_text(
        "\n".join(
            [
                f"# ALFa-AI train export {ts}",
                "",
                f"Workspace: `{workspace_root()}`",
                f"Created: {report.created_at}",
                "",
                "## Files",
                "",
                "- `preference-pack.jsonl` — raw chosen/rejected",
                "- `preference-dpo.jsonl` — DPO-oriented rows",
                "- `lessons-chat-sft.jsonl` — chat SFT from sleep lessons",
                "- `error-fix-chat-sft.jsonl` — chat seeds from error catalog",
                "- `lessons.md` — human-readable lessons",
                "",
                "## Hub staging (operator)",
                "",
                f"Copy this directory to hub: `{report.hub_hint}/{ts}/`",
                "",
                "Or run: `bash scripts/publish_train_pack_to_hub.sh`",
                "",
                "MANIFEST contract: docs/operations/TRAIN_PACK_MANIFEST.md",
                "",
                "Then on trainer island (`gaming-c`):",
                "",
                "```text",
                "python scripts/ingest_alfa_ai_pack.py --pack /path/to/export",
                "```",
                "",
                "See alfa-train docs/SLEEP_TIER_B_FROM_ALFA_AI.md",
                "",
            ]
        ),
        encoding="utf-8",
    )
    report.files["readme"] = str(readme)

    # MANIFEST with hashes (relative paths for alfa-train ingest)
    manifest: dict[str, Any] = {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "pack_id": ts,
        "created_at": report.created_at,
        "git_sha": resolve_git_sha(),
        "base_model_target": train_base_model_target(),
        "workspace": str(workspace_root()),
        "hub_hint": report.hub_hint,
        "counts": report.counts,
        "files": {},
        "feedback_inbox_rows": len(load_feedback_rows()),
        "preference_pairs_live": len(pairs_from_feedback()),
    }
    for key, path_str in report.files.items():
        p = Path(path_str)
        if not p.is_file() or p.suffix not in {".jsonl", ".md"}:
            continue
        rel = p.name
        try:
            manifest["files"][key] = {
                "path": rel,
                "bytes": p.stat().st_size,
                "sha256": _sha256_file(p),
            }
        except OSError:
            manifest["files"][key] = {"path": rel}
    man_path = root / "MANIFEST.json"
    man_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    report.files["manifest"] = str(man_path)

    # Latest symlink-like pointer file (Windows-friendly copy of path)
    latest = train_export_root() / "LATEST.txt"
    latest.write_text(str(root) + "\n", encoding="utf-8")
    report.files["latest_pointer"] = str(latest)

    report_path = root / "export-report.json"
    report_path.write_text(
        json.dumps(report.to_dict(), indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    report.files["export_report"] = str(report_path)

    if report.counts.get("dpo_rows", 0) == 0 and report.counts.get("lesson_chat_rows", 0) == 0:
        report.notes.append(
            "No DPO or lesson chat rows yet — still valid staging; collect feedback/thumbs first"
        )
    return report
