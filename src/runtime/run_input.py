"""Materialize run input files into the agent workspace (contracts-bot orchestrator path)."""

from __future__ import annotations

from pathlib import Path

from src.config import run_input_max_file_chars, run_input_max_files, workspace_root


class RunInputError(ValueError):
    """Invalid filename or input payload for a run."""


def sanitize_run_input_filename(filename: str) -> str:
    """Basename only; reject path traversal."""
    raw = (filename or "").strip()
    if not raw:
        raise RunInputError("filename must not be empty")
    normalized = raw.replace("\\", "/")
    if ".." in normalized.split("/"):
        raise RunInputError(f"invalid filename: {filename!r}")
    name = Path(raw).name
    if not name or name in {".", ".."}:
        raise RunInputError(f"invalid filename: {filename!r}")
    return name


def run_input_dir(run_id: str) -> Path:
    return workspace_root() / "runs" / run_id / "input"


def materialize_run_input_files(
    run_id: str,
    input_files: list[dict[str, str]],
) -> list[str]:
    """
    Write input_files [{filename, content}] under runs/{run_id}/input/.
    Returns relative paths written (from workspace root).
    """
    if not input_files:
        return []
    max_files = run_input_max_files()
    if len(input_files) > max_files:
        raise RunInputError(f"too many input files (max {max_files})")

    max_chars = run_input_max_file_chars()
    target_dir = run_input_dir(run_id)
    target_dir.mkdir(parents=True, exist_ok=True)
    base = workspace_root()
    written: list[str] = []

    for item in input_files:
        filename = sanitize_run_input_filename(str(item.get("filename") or ""))
        content = str(item.get("content") or "")
        if len(content) > max_chars:
            raise RunInputError(
                f"file {filename!r} exceeds max size ({max_chars} chars)"
            )
        dest = (target_dir / filename).resolve()
        try:
            dest.relative_to(base.resolve())
        except ValueError as exc:
            raise RunInputError(f"path escapes workspace: {filename}") from exc
        dest.write_text(content, encoding="utf-8")
        written.append(dest.relative_to(base).as_posix())

    return written
