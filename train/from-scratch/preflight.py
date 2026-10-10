"""Preflight for the .45b from-scratch trainer (no training, no Decoder, no NCCL init).

Distributed training uses NCCL on Linux/WSL; Windows PyTorch does not ship NCCL:
https://docs.pytorch.org/docs/2.14/distributed.html
Multi-process launch via torchrun:
https://docs.pytorch.org/docs/2.14/elastic/run.html
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_PKG = Path(__file__).resolve().parent
if str(_PKG) not in sys.path:
    sys.path.insert(0, str(_PKG))

from check_wheel import wheel_problem  # noqa: E402
from fs_gpu import island_gpu_problem  # noqa: E402
from fs_vram import reserve_bytes_for_host  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]

NCCL_DOC = "https://docs.pytorch.org/docs/2.14/distributed.html"


def checkpoint_dir_problem(path: Path, repo_root: Path) -> str | None:
    """Hub checkpoints must not live inside the git checkout. Torch-free."""
    resolved = path.resolve()
    root = repo_root.resolve()
    if resolved == root or root in resolved.parents:
        return "checkpoints go on the hub HDD, not in the git checkout"
    return None


def _train_shard_paths(data_dir: Path) -> list[Path]:
    root = data_dir / "train"
    paths = sorted(root.glob("*/shard-*.bin"))
    if not paths:
        paths = sorted(root.glob("shard-*.bin"))
    return paths


def data_dir_problem(data_dir: Path) -> str | None:
    if not data_dir.is_dir():
        return f"data dir {data_dir} is missing or not a directory"
    if not (data_dir / "RUN_CONFIG.json").is_file():
        return "RUN_CONFIG.json is missing from the data dir"
    if not _train_shard_paths(data_dir):
        return "no train shards under the data dir"
    return None


def desktop_reserve_problem(reserve_gb: float | None) -> str | None:
    if reserve_gb is None:
        return "--desktop-reserve-gb is required"
    try:
        reserve_bytes_for_host(None, reserve_gb)
    except ValueError as exc:
        return str(exc)
    return None


def visible_gpu_problem(gpu_name: str | None, *, cuda_available: bool) -> str | None:
    """Island GPU gate; tests pass gpu_name without calling CUDA."""
    if not cuda_available:
        return "cuda device is not available"
    if gpu_name is None or not gpu_name.strip():
        return "no visible GPU name"
    return island_gpu_problem(gpu_name)


def nccl_distributed_problem(*, is_nccl_available: bool) -> str | None:
    if is_nccl_available:
        return None
    return (
        "Windows PyTorch does not ship NCCL and this rank must run in WSL/Linux. "
        f"See {NCCL_DOC}"
    )


def tokenizer_problem(tokenizer_json: Path | None) -> str | None:
    if tokenizer_json is None:
        return None
    if not tokenizer_json.is_file():
        return f"tokenizer json {tokenizer_json} is missing"
    return None


def paths_problem(checkpoint_dir: Path, repo_root: Path, reserve_gb: float | None) -> str | None:
    problem = checkpoint_dir_problem(checkpoint_dir, repo_root)
    if problem:
        return problem
    return desktop_reserve_problem(reserve_gb)


def check_torch_wheel() -> tuple[str | None, str | None]:
    """Return (fail_message, pass_line). Does not run matmul."""
    try:
        import torch
    except ImportError:
        return "torch is not installed", None
    problem = wheel_problem(torch.__version__, getattr(torch.version, "cuda", None))
    if problem:
        return problem, None
    cuda = getattr(torch.version, "cuda", None)
    return None, f"PASS torch {torch.__version__} cuda {cuda}"


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Preflight checks for from-scratch training.")
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--checkpoint-dir", type=Path, required=True)
    parser.add_argument(
        "--desktop-reserve-gb",
        type=float,
        required=True,
        help="GiB to leave for the Win11 desktop (e.g. 3 on orchestrator/gaming-c/gaming-b, 0 on inference).",
    )
    parser.add_argument("--tokenizer-json", type=Path, default=None)
    parser.add_argument(
        "--distributed",
        action="store_true",
        help="Require NCCL (Linux/WSL ranks only).",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)

    problem = data_dir_problem(args.data_dir)
    if problem:
        print(f"FAIL {problem}", file=sys.stderr)
        return 1
    print("PASS data dir RUN_CONFIG.json and train shards")

    tok_problem = tokenizer_problem(args.tokenizer_json)
    if tok_problem:
        print(f"FAIL {tok_problem}", file=sys.stderr)
        return 1
    if args.tokenizer_json is not None:
        print(f"PASS tokenizer json {args.tokenizer_json}")
    else:
        print("NOTE the real run needs --tokenizer-json pointing at tokenizer.json")

    path_problem = paths_problem(args.checkpoint_dir, REPO_ROOT, args.desktop_reserve_gb)
    if path_problem:
        print(f"FAIL {path_problem}", file=sys.stderr)
        return 2
    print(f"PASS checkpoint dir outside repo ({args.checkpoint_dir})")
    print(f"PASS desktop reserve {args.desktop_reserve_gb} GiB")

    wheel_fail, wheel_pass = check_torch_wheel()
    if wheel_fail:
        print(f"FAIL {wheel_fail}", file=sys.stderr)
        return 1
    if wheel_pass:
        print(wheel_pass)

    import torch

    cuda_ok = torch.cuda.is_available()
    gpu_name: str | None = None
    if cuda_ok:
        gpu_name = torch.cuda.get_device_name(0)
    gpu_problem = visible_gpu_problem(gpu_name, cuda_available=cuda_ok)
    if gpu_problem:
        print(f"FAIL {gpu_problem}", file=sys.stderr)
        return 3
    print(f"PASS visible GPU {gpu_name}")

    if args.distributed:
        nccl_problem = nccl_distributed_problem(is_nccl_available=torch.distributed.is_nccl_available())
        if nccl_problem:
            print(f"FAIL {nccl_problem}", file=sys.stderr)
            return 4
        print("PASS NCCL available for distributed training")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
