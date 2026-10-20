"""LoRA adapter registry (hub manifest mirror in ALFA_AI_DATA).

Does not load adapters — coordinator deploy reads LORA_GGUF from .env.rpc.
See docs/operations/LORA_ADAPTER_OPERATOR.md.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from src.config import alfa_ai_data_dir, get


def lora_registry_path() -> Path:
    configured = get("ALFA_AI_LORA_REGISTRY_PATH", "").strip()
    if configured:
        return Path(configured).expanduser().resolve()
    return alfa_ai_data_dir() / "lora" / "lora-adapters.json"


def hub_lora_root_hint() -> str:
    return get(
        "ALFA_AI_LORA_HUB_ROOT",
        "/mnt/hub/alfa-ai/llama-cpp/lora",
    ).strip()


def hub_lora_manifest_path() -> Path:
    configured = get("ALFA_AI_LORA_HUB_MANIFEST", "").strip()
    if configured:
        return Path(configured).expanduser().resolve()
    return Path(hub_lora_root_hint()).expanduser() / "lora-adapters.json"


def min_eval_score() -> float:
    raw = get("ALFA_AI_LORA_MIN_EVAL_SCORE", "0.70").strip()
    try:
        return float(raw)
    except ValueError:
        return 0.70


@dataclass(slots=True)
class LoraAdapterRecord:
    adapter_id: str
    base_model: str
    gguf_relpath: str
    eval_score: float
    promoted: bool = False
    created_at: str = ""
    notes: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "adapter_id": self.adapter_id,
            "base_model": self.base_model,
            "gguf_relpath": self.gguf_relpath,
            "eval_score": self.eval_score,
            "promoted": self.promoted,
            "created_at": self.created_at,
            "notes": self.notes,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> LoraAdapterRecord:
        return cls(
            adapter_id=str(data.get("adapter_id") or ""),
            base_model=str(data.get("base_model") or ""),
            gguf_relpath=str(data.get("gguf_relpath") or ""),
            eval_score=float(data.get("eval_score") or 0.0),
            promoted=bool(data.get("promoted")),
            created_at=str(data.get("created_at") or ""),
            notes=str(data.get("notes") or ""),
        )


def _load_raw() -> dict[str, Any]:
    path = lora_registry_path()
    if not path.is_file():
        return {"adapters": [], "updated_at": ""}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"adapters": [], "updated_at": ""}


def _save_raw(data: dict[str, Any]) -> None:
    path = lora_registry_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    data["updated_at"] = datetime.now(tz=UTC).isoformat()
    data["hub_root_hint"] = hub_lora_root_hint()
    path.write_text(json.dumps(data, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def list_adapters(*, base_model: str | None = None) -> list[LoraAdapterRecord]:
    raw = _load_raw()
    out: list[LoraAdapterRecord] = []
    for item in raw.get("adapters") or []:
        if not isinstance(item, dict):
            continue
        rec = LoraAdapterRecord.from_dict(item)
        if base_model and rec.base_model != base_model:
            continue
        out.append(rec)
    return out


def register_adapter(
    *,
    adapter_id: str,
    base_model: str,
    gguf_relpath: str,
    eval_score: float,
    promoted: bool = False,
    notes: str = "",
) -> LoraAdapterRecord:
    if eval_score < min_eval_score() and promoted:
        raise ValueError(
            f"eval_score {eval_score} below ALFA_AI_LORA_MIN_EVAL_SCORE {min_eval_score()}"
        )
    rec = LoraAdapterRecord(
        adapter_id=adapter_id,
        base_model=base_model,
        gguf_relpath=gguf_relpath,
        eval_score=eval_score,
        promoted=promoted,
        created_at=datetime.now(tz=UTC).isoformat(),
        notes=notes,
    )
    raw = _load_raw()
    adapters = [a for a in (raw.get("adapters") or []) if a.get("adapter_id") != adapter_id]
    adapters.append(rec.to_dict())
    raw["adapters"] = adapters
    _save_raw(raw)
    return rec


def sync_registry_from_hub(*, hub_manifest: Path | None = None) -> dict[str, Any]:
    """Copy hub lora-adapters.json into the brain registry (merge by adapter_id).

    Does not set coordinator LORA_GGUF. Promoted flags below the eval gate are
    stored as not promoted.
    """
    src = hub_manifest or hub_lora_manifest_path()
    if not src.is_file():
        return {
            "ok": False,
            "reason": "hub_manifest_missing",
            "path": str(src),
            "imported": 0,
            "skipped": 0,
        }
    try:
        raw = json.loads(src.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        return {
            "ok": False,
            "reason": "hub_manifest_unreadable",
            "path": str(src),
            "error": str(exc),
            "imported": 0,
            "skipped": 0,
        }
    imported = 0
    skipped = 0
    for item in raw.get("adapters") or []:
        if not isinstance(item, dict):
            skipped += 1
            continue
        rec = LoraAdapterRecord.from_dict(item)
        if not rec.adapter_id or not rec.gguf_relpath:
            skipped += 1
            continue
        promoted = rec.promoted
        notes = rec.notes
        if promoted and rec.eval_score < min_eval_score():
            promoted = False
            notes = (notes + " " if notes else "") + "hub promoted clamped (eval below gate)"
        register_adapter(
            adapter_id=rec.adapter_id,
            base_model=rec.base_model,
            gguf_relpath=rec.gguf_relpath,
            eval_score=rec.eval_score,
            promoted=promoted,
            notes=notes,
        )
        imported += 1
    return {
        "ok": True,
        "path": str(src),
        "imported": imported,
        "skipped": skipped,
        "adapters": len(list_adapters()),
    }


def best_adapter_for_base(base_model: str) -> LoraAdapterRecord | None:
    candidates = [
        r
        for r in list_adapters(base_model=base_model)
        if r.promoted and r.eval_score >= min_eval_score()
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda r: r.eval_score)
