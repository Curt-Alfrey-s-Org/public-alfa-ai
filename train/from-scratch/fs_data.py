"""Read packed uint32 shards written by the corpus tool."""

from __future__ import annotations

from pathlib import Path

import torch

from fs_pack import read_u32_shard


def shard_paths(data_dir: Path, split: str) -> list[Path]:
    root = data_dir / split
    paths = sorted(root.glob("*/shard-*.bin"))
    if not paths:
        paths = sorted(root.glob("shard-*.bin"))
    return paths


def load_windows(data_dir: Path, split: str, seq_len: int) -> torch.Tensor:
    paths = shard_paths(data_dir, split)
    if not paths:
        raise FileNotFoundError(f"no {split} shards under {data_dir}")
    rows: list[list[int]] = []
    for path in paths:
        rows.extend(read_u32_shard(path, seq_len))
    if not rows:
        raise FileNotFoundError(f"{split} shards under {data_dir} are empty")
    return torch.tensor(rows, dtype=torch.long)


def load_windows_by_repo(data_dir: Path, split: str, seq_len: int) -> dict[str, torch.Tensor]:
    """One tensor per repo directory under the split."""
    root = data_dir / split
    if not root.is_dir():
        raise FileNotFoundError(f"no {split} shards under {data_dir}")
    by_repo: dict[str, torch.Tensor] = {}
    for repo_dir in sorted(path for path in root.iterdir() if path.is_dir()):
        paths = sorted(repo_dir.glob("shard-*.bin"))
        rows: list[list[int]] = []
        for path in paths:
            rows.extend(read_u32_shard(path, seq_len))
        if rows:
            by_repo[repo_dir.name] = torch.tensor(rows, dtype=torch.long)
    if not by_repo:
        raise FileNotFoundError(f"{split} shards under {data_dir} are empty")
    return by_repo


def rank_slice(windows: torch.Tensor, rank: int, world_size: int) -> torch.Tensor:
    if world_size < 1 or rank < 0 or rank >= world_size:
        raise ValueError(f"bad rank {rank} of world {world_size}")
    sliced = windows[rank::world_size]
    if sliced.shape[0] == 0:
        raise ValueError(f"rank {rank} received no windows from {windows.shape[0]}")
    return sliced
