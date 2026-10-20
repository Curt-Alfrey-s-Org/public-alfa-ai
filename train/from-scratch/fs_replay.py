"""Ordinary-commit replay. Old tokens stay the majority of the batch.

The learning rate is not re-warmed. A large new repo is a different mix,
and this module refuses that case instead of shrinking the old corpus.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import torch


def changed_paths(old_texts: dict[str, str], new_texts: dict[str, str]) -> list[str]:
    """Paths that are new or whose text differs. Removed paths stay in the old corpus."""
    return sorted(rel for rel, text in new_texts.items() if old_texts.get(rel) != text)


def git_changed_paths(root: Path, old_sha: str) -> list[str]:
    """Files changed between old_sha and HEAD. Requires a local git checkout."""
    proc = subprocess.run(
        ["git", "diff", "--name-only", old_sha, "HEAD"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip() or f"exit {proc.returncode}"
        raise RuntimeError(f"git diff failed in {root}: {detail}")
    return sorted(line.strip().replace("\\", "/") for line in proc.stdout.splitlines() if line.strip())


def replay_windows(old: torch.Tensor, changed: torch.Tensor, upsample: int) -> torch.Tensor:
    """Previous corpus, plus `upsample` copies of the changed windows."""
    if upsample < 1:
        raise ValueError("upsample must be a positive integer")
    if old.ndim != 2 or old.shape[0] < 1:
        raise ValueError("the previous corpus has no windows")
    if changed.numel() == 0:
        return old
    if changed.ndim != 2 or changed.shape[1] != old.shape[1]:
        raise ValueError("changed windows must match the previous sequence length")
    extra = changed.shape[0] * upsample
    if extra >= old.shape[0]:
        raise ValueError(
            "changed windows are no longer a small delta. "
            "Ordinary replay keeps the previous corpus as most of the batch."
        )
    repeated = changed.repeat((upsample, 1))
    return torch.cat((old, repeated), dim=0)


def forgetting(retained_now: float, retained_first: float) -> float:
    return retained_now - retained_first


def remember_baseline(stored: dict[str, float], retained: dict[str, float]) -> dict[str, float]:
    """Keep the first retained loss recorded for each repo."""
    merged = dict(stored)
    for repo, value in retained.items():
        if repo not in merged:
            merged[repo] = float(value)
    return merged


def replay_log(
    learned: float | None,
    retained: dict[str, float],
    baseline: dict[str, float],
) -> dict:
    record: dict = {"rewarm": False, "retained_loss": retained}
    if learned is not None:
        record["learned_loss"] = learned
    record["forgetting"] = {
        repo: forgetting(value, baseline[repo]) for repo, value in retained.items() if repo in baseline
    }
    return record


def retention_stopped(retained_means: list[float], patience: int) -> bool:
    """True when the last `patience` means do not beat the best before them."""
    if patience < 1 or len(retained_means) < patience + 1:
        return False
    best_before = min(retained_means[:-patience])
    return min(retained_means[-patience:]) >= best_before
