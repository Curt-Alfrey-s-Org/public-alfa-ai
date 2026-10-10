"""Mission / implement memory -- model-agnostic persistence across agent runs.

Stores dated summaries under $ALFA_AI_DATA/implement-memory/<repo-hash>.md so
researcher and coder roles recall prior work regardless of ALFA_AI_AGENT_MODEL.
See docs/AGENT_RESEARCH_TOOLS.md.
"""

from __future__ import annotations

import hashlib
import re
from datetime import UTC, datetime
from pathlib import Path

from src.config import (
    alfa_ai_data_dir,
    memory_load_max_chars,
    memory_max_entries,
    memory_max_file_bytes,
    workspace_root,
)

_GOAL_RE = re.compile(r"^\*\*Goal:\*\*\s*(.+)$", re.MULTILINE)
_SUMMARY_RE = re.compile(
    r"^\*\*Summary:\*\*\s*\n(.*?)(?=^\*\*Sources:\*\*|\n---|\Z)",
    re.MULTILINE | re.DOTALL,
)
_SOURCES_RE = re.compile(
    r"^\*\*Sources:\*\*\s*\n(.*?)(?=\n---|\Z)",
    re.MULTILINE | re.DOTALL,
)


def repo_hash(root: Path | None = None) -> str:
    """Stable identifier for the workspace clone."""
    base = (root or workspace_root()).resolve()
    remote = _git_remote_url(base)
    key = remote if remote else str(base)
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
    return digest[:16]


def memory_dir() -> Path:
    path = alfa_ai_data_dir() / "implement-memory"
    path.mkdir(parents=True, exist_ok=True)
    return path


def memory_path(root: Path | None = None) -> Path:
    return memory_dir() / f"{repo_hash(root)}.md"


def load_memory(max_chars: int | None = None) -> str:
    """Load prior mission memory, truncated for LLM context budgets."""
    path = memory_path()
    if not path.is_file():
        return ""
    raw = path.read_text(encoding="utf-8").strip()
    if not raw:
        return ""
    limit = max_chars if max_chars is not None else memory_load_max_chars()
    if len(raw) <= limit:
        return raw
    return "...(truncated)\n" + raw[-limit:]


def _memory_blocks_from_raw(raw: str) -> list[str]:
    text = raw.strip()
    if not text:
        return []
    if text.startswith("# Mission memory"):
        text = text[len("# Mission memory"):].strip()
    if not text:
        return []
    return [b.strip() for b in text.split("\n---\n") if b.strip()]


def _memory_blocks() -> list[str]:
    path = memory_path()
    if not path.is_file():
        return []
    return _memory_blocks_from_raw(path.read_text(encoding="utf-8"))


def _join_memory_file(blocks: list[str]) -> str:
    if not blocks:
        return "# Mission memory"
    return "# Mission memory\n\n" + "\n\n---\n\n".join(blocks)


def list_recent_mission_summaries(limit: int = 3) -> list[dict[str, str]]:
    """Parse the last N mission blocks from the memory file."""
    summaries: list[dict[str, str]] = []
    for block in reversed(_memory_blocks()):
        if len(summaries) >= limit:
            break
        goal_match = _GOAL_RE.search(block)
        summary_match = _SUMMARY_RE.search(block)
        if not goal_match or not summary_match:
            continue
        goal = goal_match.group(1).strip()
        summary = summary_match.group(1).strip()
        sources_match = _SOURCES_RE.search(block)
        sources = sources_match.group(1).strip() if sources_match else ""
        if not goal or not summary:
            continue
        summaries.append({"goal": goal, "summary": summary, "sources": sources})
    return summaries


def build_memory_prompt(role: str | None) -> str:
    """Inject prior memory into system prompt for researcher/coder roles."""
    if role not in {"researcher", "coder"}:
        return ""
    recent = list_recent_mission_summaries(limit=3)
    parts: list[str] = []
    if recent:
        lines = ["## Recent missions", ""]
        for idx, item in enumerate(recent, start=1):
            lines.append(f"### Mission {idx}")
            lines.append(f"Goal: {item['goal']}")
            lines.append(item["summary"])
            if item.get("sources"):
                lines.append(f"Sources: {item['sources']}")
            lines.append("")
        parts.append("\n".join(lines).strip())
    full = load_memory()
    if full:
        parts.append(f"## Prior mission memory\n\n{full}")
    if not parts:
        return ""
    return "\n\n" + "\n\n".join(parts) + "\n"


def append_mission_summary(
    goal: str,
    summary: str,
    sources: str = "",
    *,
    root: Path | None = None,
) -> Path:
    """Append a dated mission block; trim file to configured caps."""
    path = memory_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    goal_clean = goal.strip() or "(no goal)"
    summary_clean = summary.strip() or "(no summary)"
    sources_clean = sources.strip()
    ts = datetime.now(tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    block_lines = [
        f"## {ts}",
        f"**Goal:** {goal_clean}",
        "",
        "**Summary:**",
        summary_clean,
    ]
    if sources_clean:
        block_lines.extend(["", "**Sources:**", sources_clean])
    block = "\n".join(block_lines)
    existing_blocks = _memory_blocks_from_raw(
        path.read_text(encoding="utf-8") if path.is_file() else ""
    )
    existing_blocks.append(block)
    combined = _trim_memory_blocks(existing_blocks)
    path.write_text(combined + "\n", encoding="utf-8")
    return path


def _trim_memory_blocks(blocks: list[str]) -> str:
    """Keep file within byte and entry limits (drop oldest entries first)."""
    max_bytes = memory_max_file_bytes()
    max_entries = memory_max_entries()
    trimmed = list(blocks)
    while len(trimmed) > max_entries:
        trimmed.pop(0)
    while trimmed:
        body = _join_memory_file(trimmed)
        if len(body.encode("utf-8")) <= max_bytes:
            return body
        trimmed.pop(0)
    return "# Mission memory"


def _trim_memory_file(content: str) -> str:
    return _trim_memory_blocks(_memory_blocks_from_raw(content))


def _git_remote_url(root: Path) -> str:
    git_dir = root / ".git"
    if not git_dir.is_dir():
        return ""
    config = git_dir / "config"
    if not config.is_file():
        return ""
    try:
        text = config.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("url ="):
            return line.split("=", 1)[1].strip()
    return ""
