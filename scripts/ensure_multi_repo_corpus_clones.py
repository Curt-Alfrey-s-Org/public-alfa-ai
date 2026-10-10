#!/usr/bin/env python3
"""Clone or fast-forward orchestrator corpus trees from GitHub.

GitHub is the sync bus ([git clone](https://git-scm.com/docs/git-clone),
[git pull --ff-only](https://git-scm.com/docs/git-pull)). Do not SCP code from
owning hosts. Same repo on many hosts is one clone on orchestrator.

Usage:
  python scripts/ensure_multi_repo_corpus_clones.py \\
    --repos-file deploy/training/multi-repo-corpus.repos.yaml
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from build_multi_repo_corpus import load_repos_config


def run_git(args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    # Windows MAX_PATH: Git for Windows core.longpaths (git-config).
    # https://git-scm.com/docs/git-config#Documentation/git-config.txt-corelongPaths
    # https://git-scm.com/docs/git#Documentation/git.txt--cltnamegtltvaluegt
    prefixed = ["git", "-c", "core.longpaths=true"] + args[1:] if args[:1] == ["git"] else args
    return subprocess.run(
        prefixed,
        cwd=str(cwd) if cwd is not None else None,
        capture_output=True,
        text=True,
        check=False,
    )


def dir_is_empty(path: Path) -> bool:
    try:
        next(path.iterdir())
    except StopIteration:
        return True
    except OSError:
        return False
    return False


def ensure_repo(repo_id: str, root: Path, github: str, required: bool) -> int:
    git_dir = root / ".git"
    if git_dir.is_dir():
        porcelain = run_git(["git", "status", "--porcelain"], cwd=root)
        if porcelain.returncode != 0:
            print(f"ERROR git status failed: {repo_id}: {porcelain.stderr.strip()}", file=sys.stderr)
            return 1
        if porcelain.stdout.strip():
            print(f"WARN dirty working tree, skip pull (builder uses git HEAD): {repo_id}")
            return 0
        pulled = run_git(["git", "pull", "--ff-only"], cwd=root)
        if pulled.returncode != 0:
            print(
                f"ERROR git pull --ff-only failed: {repo_id}: {pulled.stderr.strip()}",
                file=sys.stderr,
            )
            return 1
        print(f"ok pull {repo_id}")
        return 0

    if not github:
        msg = f"repo root is not a git clone and github is empty: {repo_id} -> {root}"
        print(f"ERROR {msg}", file=sys.stderr)
        return 1 if required else 0

    if root.exists() and not dir_is_empty(root):
        print(
            f"ERROR dest exists, is not a git clone, and is not empty: {repo_id} -> {root}",
            file=sys.stderr,
        )
        return 1

    root.parent.mkdir(parents=True, exist_ok=True)
    cloned = run_git(["git", "clone", github, str(root)])
    if cloned.returncode != 0:
        print(
            f"ERROR git clone failed: {repo_id} {github}: {cloned.stderr.strip()}",
            file=sys.stderr,
        )
        return 1
    print(f"ok clone {repo_id}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Ensure orchestrator GitHub clones for the fleet corpus")
    parser.add_argument(
        "--repos-file",
        type=Path,
        required=True,
        help="Repo manifest (.yaml or .json)",
    )
    args = parser.parse_args(argv)
    if not args.repos_file.is_file():
        print(f"ERROR repos file not found: {args.repos_file}", file=sys.stderr)
        return 1
    config = load_repos_config(args.repos_file.resolve())
    failures = 0
    for entry in list(config.get("repos") or []):
        repo_id = str(entry.get("id", "")).strip()
        root_raw = str(entry.get("root", "")).strip()
        github = str(entry.get("github", "")).strip()
        required = bool(entry.get("required", False))
        if not repo_id or not root_raw:
            print(f"ERROR repo entry missing id/root: {entry!r}", file=sys.stderr)
            failures += 1
            continue
        failures += ensure_repo(repo_id, Path(root_raw).expanduser(), github, required)
    if failures:
        print(f"ERROR ensure clones failed count={failures}", file=sys.stderr)
        return 1
    print("ok all corpus clones present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
