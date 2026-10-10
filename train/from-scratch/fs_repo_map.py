"""Read repo ids from docs/REPO_HOST_MAPPING.md.

The mapping file is the corpus list. Local checkout paths come from the
existing multi-repo yaml, not from a second hardcoded list.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

_REPO_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_HEADING = "repo / stack"


@dataclass(frozen=True)
class RepoMap:
    repo_ids: list[str]
    skipped_rows: list[str]


def _cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def _repo_id_from_cell(cell: str) -> str | None:
    text = cell.replace("**", "").replace("`", "").strip()
    text = re.sub(r"\s*\([^)]*\)", "", text).strip()
    if not _REPO_ID.fullmatch(text):
        return None
    return text


def parse_repo_map(text: str) -> RepoMap:
    """Parse the Repo / Stack table. Other tables in the file are ignored."""
    lines = text.splitlines()
    header_index = None
    for index, line in enumerate(lines):
        if not line.startswith("|"):
            continue
        cells = [cell.casefold() for cell in _cells(line)]
        if cells and _HEADING in cells[0]:
            header_index = index
            break
    if header_index is None:
        raise ValueError("REPO_HOST_MAPPING.md has no Repo / Stack table")

    repo_ids: list[str] = []
    skipped: list[str] = []
    seen: set[str] = set()
    for line in lines[header_index + 2 :]:
        if not line.startswith("|"):
            break
        cells = _cells(line)
        if not cells or set(cells[0]) <= {"-", ":"}:
            continue
        label = cells[0].replace("**", "").replace("`", "").strip()
        repo_id = _repo_id_from_cell(cells[0])
        if repo_id is None:
            skipped.append(label)
            continue
        key = repo_id.casefold()
        if key in seen:
            continue
        seen.add(key)
        repo_ids.append(repo_id)
    if not repo_ids:
        raise ValueError("Repo / Stack table listed no repos")
    return RepoMap(repo_ids=repo_ids, skipped_rows=skipped)


def load_repo_map(path: Path) -> RepoMap:
    return parse_repo_map(path.read_text(encoding="utf-8"))
