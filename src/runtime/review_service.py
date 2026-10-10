"""Synchronous agent review for POST /api/agent/review (Pattern C consumers)."""

from __future__ import annotations

import re
import uuid
from pathlib import Path
from typing import Any

from src.agent.loop import run_agent
from src.config import agent_max_steps, agent_model, audit_root_map, workspace_root
from src.runtime.review_parse import parse_review_issues

_SAFE_REPO = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$")


def resolve_review_root(repo: str) -> Path:
    """Map logical repo name to filesystem path via ALFA_AI_AUDIT_ROOTS or workspace."""
    name = (repo or "").strip()
    if not name:
        raise ValueError("repo is required")
    roots = audit_root_map()
    if name in roots:
        return roots[name]
    # Allow bare workspace when repo matches workspace directory name
    ws = workspace_root()
    if name == ws.name or name in ("alfa-ai", "workspace", "."):
        return ws
    if roots:
        raise ValueError(
            f"Unknown repo '{name}'. Known: {', '.join(sorted(roots))} "
            "(set ALFA_AI_AUDIT_ROOTS=name=/path)"
        )
    if not _SAFE_REPO.match(name):
        raise ValueError("invalid repo name")
    # Single-workspace fallback
    return ws


def run_review(
    *,
    repo: str,
    goal: str = "",
    diff: str = "",
    focus: str = "",
    paths: list[str] | None = None,
    max_issues: int = 50,
) -> dict[str, Any]:
    """Run read-only review agent and return structured issues JSON."""
    root = resolve_review_root(repo)
    focus_l = (focus or "correctness").strip().lower()
    if focus_l not in ("security", "correctness", "style"):
        focus_l = "correctness"
    limit = max(1, min(int(max_issues), 100))
    goal_text = (goal or "").strip() or f"{focus_l} review of {repo}"

    path_hint = ""
    if paths:
        safe_paths = [p for p in paths if isinstance(p, str) and p.strip()][:50]
        if safe_paths:
            path_hint = "Scope paths:\n" + "\n".join(f"- {p}" for p in safe_paths) + "\n\n"

    diff_block = ""
    if (diff or "").strip():
        clipped = diff.strip()[:120_000]
        diff_block = f"Review this unified diff only:\n```\n{clipped}\n```\n\n"

    prompt = (
        f"Review goal: {goal_text}\n"
        f"Repo logical name: {repo}\n"
        f"Workspace path for tools: {root}\n"
        f"Focus: {focus_l}\n\n"
        f"{path_hint}"
        f"{diff_block}"
        "Use read-only tools (grep_repo, read_file, glob_files). "
        "Output structured issues in the review skill format. "
        f"At most {limit} issues."
    )

    run_id = str(uuid.uuid4())
    result = run_agent(
        prompt,
        max_steps=min(agent_max_steps(), 8),
        role="researcher",
        skill="review",
        persona="reviewer",
        research_only=True,
        use_agent_model=True,
        run_id=run_id,
    )
    text = result if isinstance(result, str) else result.text
    issues = parse_review_issues(text, max_issues=limit)
    summary = _summary_from_text(text, issues)
    return {
        "ok": True,
        "run_id": run_id,
        "model": agent_model(),
        "issues": issues,
        "summary": summary,
        "artifact_path": None,
        "raw_preview": (text or "")[:4000],
    }


def _summary_from_text(text: str, issues: list[dict[str, Any]]) -> str:
    if not text.strip():
        return f"Review produced {len(issues)} issue(s)."
    # First non-empty paragraph before issues, or counts
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    head = []
    for ln in lines[:12]:
        if ln.startswith("### Issue"):
            break
        head.append(ln)
    if head:
        return " ".join(head)[:800]
    bugs = sum(1 for i in issues if i.get("severity") == "bug")
    return f"Review found {len(issues)} issue(s) ({bugs} bug severity)."
