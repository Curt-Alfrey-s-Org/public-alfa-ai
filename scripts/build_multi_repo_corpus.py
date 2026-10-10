#!/usr/bin/env python3
"""Build a multi-repo completion JSONL corpus for 7B QLoRA.

Each row matches Axolotl completion format (field ``content``):
https://docs.axolotl.ai/docs/dataset-formats/

Tracked files come from ``git ls-tree -r --name-only HEAD``:
https://git-scm.com/docs/git-ls-tree

Usage:
  python scripts/ensure_multi_repo_corpus_clones.py \\
    --repos-file deploy/training/multi-repo-corpus.repos.yaml
  python scripts/build_multi_repo_corpus.py \\
    --repos-file deploy/training/multi-repo-corpus.repos.yaml \\
    --out-dir C:/Users/operator/alfa-ai-cache/train-corpus/multirepo
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import random
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from scan_pass_jsonl import redact_text

TRAIN_NAME = "alfa-corpus-multirepo-train.jsonl"
VAL_NAME = "alfa-corpus-multirepo-val.jsonl"
MANIFEST_NAME = "CORPUS_MANIFEST.json"
NUL_SKIP_THRESHOLD = 3


def _strip_comment(line: str) -> str:
    in_single = False
    in_double = False
    for idx, ch in enumerate(line):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            return line[:idx]
    return line


def _parse_scalar(raw: str):
    value = raw.strip()
    if not value:
        return ""
    if value in {"true", "false"}:
        return value == "true"
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        return value[1:-1]
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def parse_simple_yaml(text: str) -> dict:
    """Parse the small subset of YAML used by multi-repo-corpus.repos.yaml."""
    root: dict = {}
    stack: list[tuple[int, dict | list]] = [(-1, root)]

    for raw_line in text.splitlines():
        line = _strip_comment(raw_line).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        content = line.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]

        if content.startswith("- "):
            item_text = content[2:].strip()
            if not isinstance(parent, list):
                raise ValueError("YAML list item without a list parent")
            if ":" in item_text:
                key, _, rest = item_text.partition(":")
                obj = {key.strip(): _parse_scalar(rest)}
                parent.append(obj)
                stack.append((indent, obj))
            else:
                parent.append(_parse_scalar(item_text))
            continue

        if ":" not in content:
            raise ValueError(f"Invalid YAML line: {raw_line!r}")
        key, _, rest = content.partition(":")
        key = key.strip()
        rest = rest.strip()
        if rest:
            if not isinstance(parent, dict):
                raise ValueError(f"YAML mapping entry without dict parent: {raw_line!r}")
            parent[key] = _parse_scalar(rest)
        else:
            if not isinstance(parent, dict):
                raise ValueError(f"YAML mapping entry without dict parent: {raw_line!r}")
            child: dict | list = []
            parent[key] = child
            stack.append((indent, child))

    return root


def load_repos_config(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".json":
        return json.loads(text)
    return parse_simple_yaml(text)


def git_short_sha(repo_root: Path) -> str | None:
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(repo_root),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    sha = (proc.stdout or "").strip()
    return sha or None


def git_tracked_relpaths(repo_root: Path) -> list[str] | None:
    """Return HEAD paths from ``git ls-tree -r --name-only``.

    Official: https://git-scm.com/docs/git-ls-tree
    Corpus rows are committed tree files, not untracked host dirt.
    """
    try:
        proc = subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", "HEAD"],
            cwd=str(repo_root),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return [line.strip().replace("\\", "/") for line in proc.stdout.splitlines() if line.strip()]


def extension_allowed(path: Path, include_extensions: list[str]) -> bool:
    lowered = {ext.lower() for ext in include_extensions}
    suffix = path.suffix.lower()
    if suffix in lowered:
        return True
    name_lower = path.name.lower()
    if name_lower == "dockerfile" and (".dockerfile" in lowered or "dockerfile" in lowered):
        return True
    return False


def path_denied(rel_posix: str, deny_dirname_substrings: list[str]) -> bool:
    """Deny when a path *directory* segment equals a deny token (not filename substrings).

    Examples: skip ``node_modules/`` or ``.git/`` dirs; do not skip ``.github/`` or
    ``scripts/build_foo.py`` just because deny lists ``.git`` / ``build``.
    """
    parts = PurePosixPath(rel_posix).parts
    # All but the final filename are directory segments.
    dir_parts = parts[:-1] if len(parts) > 1 else ()
    for token in deny_dirname_substrings:
        token_lower = token.lower().strip("/\\")
        if not token_lower:
            continue
        for part in dir_parts:
            if part.lower() == token_lower:
                return True
    return False


def name_denied(filename: str, deny_name_globs: list[str]) -> bool:
    for pattern in deny_name_globs:
        if fnmatch.fnmatch(filename, pattern):
            return True
        if fnmatch.fnmatch(filename.lower(), pattern.lower()):
            return True
    return False


def fixture_secret_denied(rel_posix: str, filename: str) -> bool:
    """Skip fixture files whose names suggest embedded secrets."""
    parts_lower = [part.lower() for part in PurePosixPath(rel_posix).parts]
    if "fixtures" not in parts_lower:
        return False
    return "secret" in filename.lower()


def read_text_file(path: Path, max_file_bytes: int) -> str | None:
    try:
        size = path.stat().st_size
    except OSError:
        return None
    if size > max_file_bytes:
        return None
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if raw.count(b"\x00") > NUL_SKIP_THRESHOLD:
        return None
    text = raw.decode("utf-8", errors="replace")
    if text.count("\x00") > NUL_SKIP_THRESHOLD:
        return None
    if not text.strip():
        return None
    return text


def collect_repo_rows(
    repo_id: str,
    root: Path,
    include_extensions: list[str],
    deny_dirname_substrings: list[str],
    deny_name_globs: list[str],
    max_file_bytes: int,
) -> tuple[list[dict[str, str]], int, int]:
    rows: list[dict[str, str]] = []
    file_count = 0
    byte_total = 0
    if not root.is_dir():
        return rows, file_count, byte_total

    tracked = git_tracked_relpaths(root)
    if tracked is None:
        print(
            f"ERROR not a git checkout (git ls-tree HEAD failed): {repo_id} -> {root}",
            file=sys.stderr,
        )
        return rows, file_count, byte_total

    for rel_posix in sorted(tracked):
        path = root / rel_posix
        if not path.is_file():
            continue
        if path_denied(rel_posix, deny_dirname_substrings):
            continue
        if name_denied(path.name, deny_name_globs):
            continue
        if fixture_secret_denied(rel_posix, path.name):
            continue
        if not extension_allowed(path, include_extensions):
            continue
        content = read_text_file(path, max_file_bytes)
        if content is None:
            continue
        content, _redaction_count = redact_text(content)
        if not content.strip():
            continue
        rows.append(
            {
                "repo": repo_id,
                "path": rel_posix,
                "content": content,
            }
        )
        file_count += 1
        byte_total += len(content.encode("utf-8"))

    return rows, file_count, byte_total


def write_jsonl(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=True))
            handle.write("\n")


def build_corpus(repos_file: Path, out_dir: Path) -> int:
    config = load_repos_config(repos_file.resolve())
    val_fraction = float(config.get("val_fraction", 0.1))
    max_file_bytes = int(config.get("max_file_bytes", 262144))
    seed = int(config.get("seed", 42))
    include_extensions = list(config.get("include_extensions") or [])
    deny_dirname_substrings = list(config.get("deny_dirname_substrings") or [])
    deny_name_globs = list(config.get("deny_name_globs") or [])
    repos_cfg = list(config.get("repos") or [])

    all_rows: list[dict[str, str]] = []
    per_repo_stats: dict[str, dict[str, int]] = {}
    skipped_repos: list[dict[str, str]] = []

    for entry in repos_cfg:
        repo_id = str(entry.get("id", "")).strip()
        root_raw = str(entry.get("root", "")).strip()
        required = bool(entry.get("required", False))
        if not repo_id or not root_raw:
            print(f"WARN skipping repo entry with missing id/root: {entry!r}", file=sys.stderr)
            continue
        root = Path(root_raw).expanduser()
        if not root.is_dir() or not (root / ".git").is_dir():
            msg = f"WARN repo root missing or not a git clone: {repo_id} -> {root}"
            print(msg, file=sys.stderr)
            skipped_repos.append({"id": repo_id, "root": str(root), "reason": "missing_root"})
            if required:
                print(f"ERROR required repo missing: {repo_id}", file=sys.stderr)
                return 1
            continue

        rows, file_count, byte_total = collect_repo_rows(
            repo_id,
            root,
            include_extensions,
            deny_dirname_substrings,
            deny_name_globs,
            max_file_bytes,
        )
        if file_count == 0 and git_tracked_relpaths(root) is None:
            skipped_repos.append({"id": repo_id, "root": str(root), "reason": "not_git"})
            if required:
                print(f"ERROR required repo is not a git checkout: {repo_id}", file=sys.stderr)
                return 1
            continue
        per_repo_stats[repo_id] = {
            "files": file_count,
            "bytes": byte_total,
            "git_short_sha": git_short_sha(root) or "",
        }
        all_rows.extend(rows)
        print(f"repo={repo_id} files={file_count} bytes={byte_total}")

    if not all_rows:
        print("ERROR no corpus rows produced", file=sys.stderr)
        return 1

    rng = random.Random(seed)
    rng.shuffle(all_rows)

    val_count = max(1, int(len(all_rows) * val_fraction)) if len(all_rows) > 1 else 0
    if val_count >= len(all_rows):
        val_count = max(1, len(all_rows) // 10)
    val_rows = all_rows[:val_count]
    train_rows = all_rows[val_count:]

    if not train_rows:
        train_rows = all_rows[:-1] if len(all_rows) > 1 else all_rows
        val_rows = all_rows[-1:] if len(all_rows) > 1 else []

    out_dir.mkdir(parents=True, exist_ok=True)
    train_path = out_dir / TRAIN_NAME
    val_path = out_dir / VAL_NAME
    manifest_path = out_dir / MANIFEST_NAME

    write_jsonl(train_path, train_rows)
    write_jsonl(val_path, val_rows)

    alfa_ai_root = Path(__file__).resolve().parents[1]
    manifest = {
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "seed": seed,
        "val_fraction": val_fraction,
        "repos": per_repo_stats,
        "totals": {
            "rows": len(all_rows),
            "train_rows": len(train_rows),
            "val_rows": len(val_rows),
            "bytes": sum(len(r["content"].encode("utf-8")) for r in all_rows),
        },
        "skipped_repos": skipped_repos,
        "out_paths": {
            "train": str(train_path),
            "val": str(val_path),
            "manifest": str(manifest_path),
        },
        "alfa_ai_git_short_sha": git_short_sha(alfa_ai_root),
        "repos_file": str(repos_file.resolve()),
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

    print(
        "summary "
        f"rows={len(all_rows)} train={len(train_rows)} val={len(val_rows)} "
        f"repos={len(per_repo_stats)} skipped={len(skipped_repos)} out_dir={out_dir}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build multi-repo completion JSONL corpus")
    parser.add_argument(
        "--repos-file",
        type=Path,
        required=True,
        help="Repo manifest (.yaml or .json)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        required=True,
        help="Output directory for JSONL + manifest",
    )
    args = parser.parse_args(argv)
    if not args.repos_file.is_file():
        print(f"ERROR repos file not found: {args.repos_file}", file=sys.stderr)
        return 1
    return build_corpus(args.repos_file, args.out_dir.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
