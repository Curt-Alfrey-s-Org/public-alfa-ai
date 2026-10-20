"""Single-island trainer CLI.

  python train/from-scratch/train.py --data-dir <stamp> --tokenizer-json <path> --max-steps 1 --desktop-reserve-gb 3 --checkpoint-dir <hub>
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fs_config import load_run_config
from fs_gpu import confirm_local, parse_hardware_table, query_nvidia_smi
from fs_model import ModelConfig
from fs_tokenizer import TokenizerError, load_hf_tokenizer
from fs_data import load_windows, load_windows_by_repo, shard_paths
from fs_replay import replay_windows
from fs_train import run_training
from fs_vram import reserve_bytes_for_host


REPO_ROOT = Path(__file__).resolve().parents[2]


def _vocab_size(stamp: dict, tokenizer_json: Path | None) -> int:
    recorded = stamp.get("vocab_size")
    if isinstance(recorded, int) and recorded > 0:
        return recorded
    if tokenizer_json is None:
        raise ValueError(
            "the stamp has no vocab_size. Pass --tokenizer-json for the corpus tokenizer snapshot."
        )
    tokenizer = load_hf_tokenizer(
        str(stamp["tokenizer_id"]),
        tokenizer_json,
        str(stamp.get("tokenizer_eos_token") or ""),
    )
    return int(tokenizer.vocab_size)


def _confirmed_host(inventory: Path) -> str | None:
    rows = parse_hardware_table(inventory.read_text(encoding="utf-8"))
    names, error = query_nvidia_smi()
    if error:
        return None
    report = confirm_local(rows, socket.gethostname(), names)
    if report.get("confirmed"):
        return str(report["host"])
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="From-scratch single-island trainer")
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--tokenizer-json", type=Path)
    parser.add_argument("--checkpoint-dir", type=Path)
    parser.add_argument("--max-steps", type=int, required=True)
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--desktop-reserve-gb", type=float)
    parser.add_argument("--compile", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--activation-checkpoint", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--log-every", type=int, default=10)
    parser.add_argument("--checkpoint-every", type=int, default=100)
    parser.add_argument("--optimizer", choices=("adamw", "muon"), default="adamw")
    parser.add_argument("--lr", type=float)
    parser.add_argument("--beta1", type=float)
    parser.add_argument("--beta2", type=float)
    parser.add_argument("--weight-decay", type=float)
    parser.add_argument("--muon-lr", type=float)
    parser.add_argument("--muon-momentum", type=float)
    parser.add_argument("--muon-weight-decay", type=float)
    parser.add_argument("--retention-patience", type=int)
    parser.add_argument("--resume", type=Path)
    parser.add_argument("--replay-from", type=Path)
    parser.add_argument("--upsample", type=int)
    parser.add_argument("--inventory", type=Path, default=REPO_ROOT / "docs" / "NODE_INVENTORY.md")
    args = parser.parse_args(argv)

    stamp_path = args.data_dir / "RUN_CONFIG.json"
    if not stamp_path.is_file():
        print(f"missing {stamp_path}", file=sys.stderr)
        return 1
    stamp = json.loads(stamp_path.read_text(encoding="utf-8"))
    shipped = load_run_config()
    model_cfg = dict(shipped["model"])
    model_cfg["seq_len"] = int(stamp.get("seq_len") or model_cfg["seq_len"])
    try:
        model_cfg["vocab_size"] = _vocab_size(stamp, args.tokenizer_json)
        config = ModelConfig(**model_cfg)
    except (TokenizerError, ValueError, KeyError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    host = _confirmed_host(args.inventory)
    try:
        reserve = reserve_bytes_for_host(host, args.desktop_reserve_gb)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    checkpoints = shipped["checkpoints"]
    checkpoint_dir = args.checkpoint_dir
    if checkpoint_dir is None:
        for key in ("smb", "nfs", "canonical"):
            candidate = Path(str(checkpoints[key]))
            if candidate.exists():
                checkpoint_dir = candidate
                break
    if checkpoint_dir is None:
        print(
            "checkpoint dir is not mounted. Pass --checkpoint-dir for "
            "/mnt/hub/alfa-ai/training/alfa-train/checkpoints/from-scratch "
            "or the training SMB share.",
            file=sys.stderr,
        )
        return 1

    adamw = shipped["adamw"]
    muon = shipped["muon"]
    replay = shipped["replay"]
    upsample = int(replay["upsample"] if args.upsample is None else args.upsample)
    lr = float(adamw["lr"] if args.lr is None else args.lr)
    beta1 = float(adamw["betas"][0] if args.beta1 is None else args.beta1)
    beta2 = float(adamw["betas"][1] if args.beta2 is None else args.beta2)
    weight_decay = float(adamw["weight_decay"] if args.weight_decay is None else args.weight_decay)
    muon_lr = float(muon["lr"] if args.muon_lr is None else args.muon_lr)
    muon_momentum = float(muon["momentum"] if args.muon_momentum is None else args.muon_momentum)
    muon_weight_decay = float(muon["weight_decay"] if args.muon_weight_decay is None else args.muon_weight_decay)
    retention_patience = int(
        replay["retention_patience"] if args.retention_patience is None else args.retention_patience
    )

    try:
        changed_windows = None
        probe_by_repo = None
        baseline_path = None
        if args.replay_from:
            old_windows = load_windows(args.replay_from, "train", config.seq_len)
            if shard_paths(args.data_dir, "changed"):
                changed_windows = load_windows(args.data_dir, "changed", config.seq_len)
            else:
                changed_windows = old_windows.new_empty((0, config.seq_len))
            train_windows = replay_windows(old_windows, changed_windows, upsample)
            probe_windows = None
            probe_by_repo = load_windows_by_repo(args.replay_from, "probe", config.seq_len)
            baseline_path = checkpoint_dir / "probe_baseline.json"
        else:
            train_windows = load_windows(args.data_dir, "train", config.seq_len)
            probe_windows = None
            if shard_paths(args.data_dir, "probe"):
                probe_windows = load_windows(args.data_dir, "probe", config.seq_len)
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    try:
        return run_training(
            config,
            train_windows,
            probe_windows,
            max_steps=args.max_steps,
            batch_size=args.batch_size,
            lr=lr,
            betas=(beta1, beta2),
            weight_decay=weight_decay,
            reserve_bytes=reserve,
            checkpoint_dir=checkpoint_dir,
            repo_root=REPO_ROOT,
            compile_blocks=bool(args.compile),
            activation_checkpoint=bool(args.activation_checkpoint),
            seed=args.seed,
            log_every=args.log_every,
            checkpoint_every=args.checkpoint_every,
            resume=args.resume,
            optimizer_kind=args.optimizer,
            muon_lr=muon_lr,
            muon_momentum=muon_momentum,
            muon_weight_decay=muon_weight_decay,
            changed_windows=changed_windows,
            probe_by_repo=probe_by_repo,
            baseline_path=baseline_path,
            retention_patience=retention_patience,
        )
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
