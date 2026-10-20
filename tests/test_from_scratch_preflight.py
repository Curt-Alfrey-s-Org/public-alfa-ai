"""CPU tests for from-scratch trainer preflight (no GPU training)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_PKG = Path(__file__).resolve().parents[1] / "train" / "from-scratch"
sys.path.insert(0, str(_PKG))

from fs_gpu import island_gpu_problem  # noqa: E402
from preflight import (  # noqa: E402
    REPO_ROOT,
    _parse_args,
    data_dir_problem,
    desktop_reserve_problem,
    nccl_distributed_problem,
    paths_problem,
    visible_gpu_problem,
)

_PREFLIGHT = _PKG / "preflight.py"


def test_island_gpu_names_for_preflight() -> None:
    assert island_gpu_problem("NVIDIA GeForce RTX 3060") is None
    assert island_gpu_problem("NVIDIA GeForce RTX 5070") is None
    assert island_gpu_problem("NVIDIA GeForce RTX 5060") is not None


def test_visible_gpu_problem_without_cuda() -> None:
    assert visible_gpu_problem("NVIDIA GeForce RTX 5070", cuda_available=False) is not None


def test_checkpoint_dir_inside_repo_fails() -> None:
    inside = REPO_ROOT / "tmp-checkpoint-preflight-test"
    assert paths_problem(inside, REPO_ROOT, 3.0) is not None


def test_checkpoint_dir_outside_repo_passes() -> None:
    outside = Path("D:/alfa-ai-hub/checkpoints/preflight-test")
    assert paths_problem(outside, REPO_ROOT, 3.0) is None


def test_desktop_reserve_required() -> None:
    assert desktop_reserve_problem(None) is not None
    assert desktop_reserve_problem(-1.0) is not None
    assert desktop_reserve_problem(3.0) is None


def test_parse_args_requires_desktop_reserve_gb() -> None:
    with pytest.raises(SystemExit):
        _parse_args(["--data-dir", "C:/data", "--checkpoint-dir", "D:/ckpt"])


def test_nccl_problem_when_unavailable() -> None:
    msg = nccl_distributed_problem(is_nccl_available=False)
    assert msg is not None
    assert "NCCL" in msg
    assert "docs.pytorch.org/docs/2.14/distributed.html" in msg
    assert nccl_distributed_problem(is_nccl_available=True) is None


def test_data_dir_without_run_config_fails(tmp_path: Path) -> None:
    assert data_dir_problem(tmp_path) is not None


def test_cli_missing_desktop_reserve_exits_nonzero() -> None:
    proc = subprocess.run(
        [sys.executable, str(_PREFLIGHT), "--data-dir", "C:/x", "--checkpoint-dir", "D:/y"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode != 0
