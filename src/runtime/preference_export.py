"""Export operator preference pairs for sleep-hour training packs (L0/L2).

Reads a simple feedback JSONL (thumbs / outcomes) if present and writes a
hub-friendly preference pack. Does not touch production model weights.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from src.config import alfa_ai_data_dir, get


@dataclass(slots=True)
class PreferencePair:
    prompt: str
    chosen: str
    rejected: str
    source: str = "operator"
    metadata: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "prompt": self.prompt,
            "chosen": self.chosen,
            "rejected": self.rejected,
            "source": self.source,
            "metadata": self.metadata or {},
        }


def feedback_inbox_path() -> Path:
    configured = get("ALFA_AI_FEEDBACK_JSONL", "").strip()
    if configured:
        return Path(configured).expanduser().resolve()
    return alfa_ai_data_dir() / "feedback.jsonl"


def preference_export_path() -> Path:
    configured = get("ALFA_AI_PREFERENCE_EXPORT_PATH", "").strip()
    if configured:
        return Path(configured).expanduser().resolve()
    return alfa_ai_data_dir() / "preference-pack.jsonl"


def append_feedback(
    *,
    prompt: str,
    response: str,
    rating: str,
    alternative: str = "",
    source: str = "operator",
    metadata: dict[str, Any] | None = None,
) -> Path:
    """Append a raw feedback row (rating: up|down|pass|fail)."""
    path = feedback_inbox_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "ts": datetime.now(tz=UTC).isoformat(),
        "prompt": (prompt or "")[:8000],
        "response": (response or "")[:8000],
        "rating": (rating or "").strip().lower(),
        "alternative": (alternative or "")[:8000],
        "source": source,
        "metadata": metadata or {},
    }
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=True) + "\n")
    return path


def append_thumbs(
    *,
    prompt: str,
    response: str,
    helpful: bool,
    source: str,
    alternative: str = "",
    metadata: dict[str, Any] | None = None,
) -> Path:
    """Map admin thumbs (helpful True/False) onto feedback.jsonl ratings."""
    return append_feedback(
        prompt=prompt,
        response=response,
        rating="up" if helpful else "down",
        alternative=alternative,
        source=source,
        metadata=metadata,
    )


def load_feedback_rows(path: Path | None = None) -> list[dict[str, Any]]:
    inbox = path or feedback_inbox_path()
    if not inbox.is_file():
        return []
    rows: list[dict[str, Any]] = []
    for line in inbox.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(raw, dict):
            rows.append(raw)
    return rows


def pairs_from_feedback(rows: list[dict[str, Any]] | None = None) -> list[PreferencePair]:
    """Build (chosen, rejected) pairs when both sides exist or synthetic reject."""
    data = rows if rows is not None else load_feedback_rows()
    by_prompt: dict[str, list[dict[str, Any]]] = {}
    for row in data:
        prompt = str(row.get("prompt") or "").strip()
        if not prompt:
            continue
        by_prompt.setdefault(prompt, []).append(row)

    pairs: list[PreferencePair] = []
    for prompt, group in by_prompt.items():
        ups = [r for r in group if str(r.get("rating") or "").lower() in ("up", "pass", "chosen")]
        downs = [
            r for r in group if str(r.get("rating") or "").lower() in ("down", "fail", "rejected")
        ]
        if ups and downs:
            pairs.append(
                PreferencePair(
                    prompt=prompt,
                    chosen=str(ups[-1].get("response") or ""),
                    rejected=str(downs[-1].get("response") or ""),
                    source=str(ups[-1].get("source") or "operator"),
                    metadata={"n_up": len(ups), "n_down": len(downs)},
                )
            )
            continue
        for row in group:
            alt = str(row.get("alternative") or "").strip()
            rating = str(row.get("rating") or "").lower()
            response = str(row.get("response") or "")
            if alt and rating in ("up", "pass", "chosen"):
                pairs.append(
                    PreferencePair(
                        prompt=prompt,
                        chosen=response,
                        rejected=alt,
                        source=str(row.get("source") or "operator"),
                    )
                )
            elif alt and rating in ("down", "fail", "rejected"):
                pairs.append(
                    PreferencePair(
                        prompt=prompt,
                        chosen=alt,
                        rejected=response,
                        source=str(row.get("source") or "operator"),
                    )
                )
    return pairs


def export_preference_pack(
    *,
    inbox: Path | None = None,
    out_path: Path | None = None,
) -> dict[str, Any]:
    pairs = pairs_from_feedback(load_feedback_rows(inbox))
    dest = out_path or preference_export_path()
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("w", encoding="utf-8") as fh:
        for pair in pairs:
            fh.write(json.dumps(pair.to_dict(), ensure_ascii=True) + "\n")
    return {
        "ok": True,
        "pairs": len(pairs),
        "path": str(dest),
        "inbox": str(inbox or feedback_inbox_path()),
        "exported_at": datetime.now(tz=UTC).isoformat(),
    }
