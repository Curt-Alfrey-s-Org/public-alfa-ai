"""Read-only learning-loop status for admin (flywheel, train-export, LoRA).

Does not start GPU train or mutate production routes.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from src.runtime.flywheel import flywheel_enabled, flywheel_root
from src.runtime.lora_registry import (
    hub_lora_manifest_path,
    hub_lora_root_hint,
    list_adapters,
    lora_registry_path,
)
from src.runtime.preference_export import load_feedback_rows, pairs_from_feedback
from src.runtime.train_export import train_export_root


def _read_pointer(path: Path) -> str:
    if not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8").strip().strip("\r")
    except OSError:
        return ""


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    return raw if isinstance(raw, dict) else None


def _summarize_flywheel(raw: dict[str, Any]) -> dict[str, Any]:
    phases: list[dict[str, Any]] = []
    for item in raw.get("phases") or []:
        if not isinstance(item, dict):
            continue
        phases.append(
            {
                "phase": item.get("phase"),
                "ok": item.get("ok"),
                "summary": item.get("summary"),
            }
        )
    return {
        "ok": raw.get("ok"),
        "started_at": raw.get("started_at"),
        "finished_at": raw.get("finished_at"),
        "dry_run": raw.get("dry_run"),
        "notes": list(raw.get("notes") or []),
        "phases": phases,
    }


def collect_learning_loop_status() -> dict[str, Any]:
    """Snapshot for GET /alfa-ai/api/admin/learning-loop/status."""
    flywheel_ptr = flywheel_root() / "LATEST.txt"
    flywheel_path = _read_pointer(flywheel_ptr)
    flywheel_raw = _read_json(Path(flywheel_path)) if flywheel_path else None

    export_root = train_export_root()
    pack_path = _read_pointer(export_root / "LATEST.txt")
    manifest: dict[str, Any] | None = None
    if pack_path:
        manifest = _read_json(Path(pack_path) / "MANIFEST.json")

    adapters = [rec.to_dict() for rec in list_adapters()]
    hub_manifest = hub_lora_manifest_path()
    return {
        "ok": True,
        "flywheel": {
            "enabled": flywheel_enabled(),
            "latest_path": flywheel_path,
            "latest": _summarize_flywheel(flywheel_raw) if flywheel_raw else None,
        },
        "train_export": {
            "latest_pack": pack_path,
            "schema_version": (manifest or {}).get("schema_version"),
            "counts": (manifest or {}).get("counts") or {},
            "scan_pass": (manifest or {}).get("scan_pass"),
            "base_model_target": (manifest or {}).get("base_model_target"),
        },
        "feedback": {
            "inbox_rows": len(load_feedback_rows()),
            "preference_pairs": len(pairs_from_feedback()),
        },
        "lora": {
            "registry_path": str(lora_registry_path()),
            "hub_root_hint": hub_lora_root_hint(),
            "hub_manifest_path": str(hub_manifest),
            "hub_manifest_present": hub_manifest.is_file(),
            "adapters": adapters,
            "count": len(adapters),
        },
    }
