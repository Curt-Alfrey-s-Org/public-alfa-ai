from __future__ import annotations

from pathlib import Path

from src.config import repo_root


def _personas_root() -> Path:
    return repo_root() / "personas"


def load_persona(name: str) -> str | None:
    persona_name = name.strip()
    if not persona_name:
        return None
    path = _personas_root() / f"{persona_name}.md"
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8").strip() or None


def build_persona_prompt(persona_name: str | None) -> str:
    if not persona_name:
        return ""
    body = load_persona(persona_name)
    if not body:
        return ""
    return f"\n\n## Persona: {persona_name}\n\n{body}\n"