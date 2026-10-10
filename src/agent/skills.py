from __future__ import annotations

import re
from pathlib import Path

from src.config import repo_root

_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n(.*)$", re.DOTALL)

_DEFAULT_SKILL_BY_ROLE: dict[str, str] = {
    "researcher": "audit-repo",
    "coder": "implement",
    "debugger": "check-work",
    "doc_maker": "review",
}


def _skills_root() -> Path:
    return repo_root() / "skills"


def parse_skill_markdown(raw: str) -> tuple[dict[str, str], str]:
    match = _FRONTMATTER_RE.match(raw.strip())
    if not match:
        return {}, raw.strip()
    frontmatter: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        frontmatter[key.strip()] = value.strip()
    return frontmatter, match.group(2).strip()


def list_skill_catalog() -> list[dict[str, str]]:
    """Return skill metadata (name + description) without instruction bodies."""
    root = _skills_root()
    if not root.is_dir():
        return []

    entries: list[dict[str, str]] = []
    for skill_dir in sorted(root.iterdir()):
        if not skill_dir.is_dir():
            continue
        skill_path = skill_dir / "SKILL.md"
        if not skill_path.is_file():
            continue
        meta, _body = parse_skill_markdown(skill_path.read_text(encoding="utf-8"))
        dir_name = skill_dir.name
        entry: dict[str, str] = {
            "name": dir_name,
            "description": meta.get("description", "").strip() or dir_name,
        }
        when_to_use = meta.get("when-to-use", "").strip()
        if when_to_use:
            entry["when_to_use"] = when_to_use
        entries.append(entry)
    return entries


def _format_skills_catalog(entries: list[dict[str, str]]) -> str:
    if not entries:
        return ""
    lines = ["\n\n## Skills catalog\n"]
    for entry in entries:
        line = f"- **{entry['name']}**: {entry['description']}"
        when_to_use = entry.get("when_to_use", "").strip()
        if when_to_use:
            line += f" (when: {when_to_use})"
        lines.append(line)
    lines.append("")
    return "\n".join(lines)


def load_skill(name: str) -> str | None:
    skill_name = name.strip()
    if not skill_name:
        return None
    path = _skills_root() / skill_name / "SKILL.md"
    if not path.is_file():
        return None
    _meta, body = parse_skill_markdown(path.read_text(encoding="utf-8"))
    return body or None


def resolve_skill_name(
    role: str,
    *,
    explicit: str | None = None,
    research_only: bool = False,
) -> str | None:
    if explicit and explicit.strip():
        return explicit.strip()
    if research_only and role == "researcher":
        return "audit-repo"
    return _DEFAULT_SKILL_BY_ROLE.get(role)


def build_skill_prompt(skill_name: str | None) -> str:
    parts: list[str] = []
    catalog_text = _format_skills_catalog(list_skill_catalog())
    if catalog_text:
        parts.append(catalog_text)
    if skill_name:
        body = load_skill(skill_name)
        if body:
            parts.append(f"\n\n## Skill: {skill_name}\n\n{body}\n")
    return "".join(parts)
