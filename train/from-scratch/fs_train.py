"""Single-island training step.

NCCL DDP via torchrun. Windows PyTorch has no NCCL, so the Windows hosts run
this in WSL.
https://docs.pytorch.org/docs/2.14/distributed.html
https://docs.pytorch.org/docs/2.14/elastic/run.html
https://docs.pytorch.org/docs/2.14/generated/torch.nn.parallel.DistributedDataParallel.html

bf16 autocast does not use GradScaler.
https://docs.pytorch.org/docs/2.13/amp.html
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict
from pathlib import Path

import torch
from torch import nn
from torch.nn.parallel import DistributedDataParallel

from fs_data import load_windows, rank_slice
from fs_gpu import island_gpu_problem
from fs_model import Decoder, ModelConfig
from fs_replay import remember_baseline, replay_log, retention_stopped
from fs_vram import apply_memory_fraction, memory_fraction
from preflight import checkpoint_dir_problem


def init_ranks() -> tuple[int, int, int]:
    """Return rank, world size, local rank. A lone process does not join NCCL."""
    if "WORLD_SIZE" not in os.environ:
        return 0, 1, 0
    world = int(os.environ["WORLD_SIZE"])
    rank = int(os.environ.get("RANK", "0"))
    local = int(os.environ.get("LOCAL_RANK", "0"))
    if world < 1:
        raise RuntimeError(f"WORLD_SIZE {world} is invalid")
    if world == 1:
        return rank, world, local
    import torch.distributed as dist

    if not dist.is_nccl_available():
        raise RuntimeError(
            "NCCL is not available. Windows PyTorch does not ship NCCL "
            "(https://docs.pytorch.org/docs/2.14/distributed.html). "
            "Run this rank in Linux or WSL Ubuntu."
        )
    dist.init_process_group(backend="nccl")
    return dist.get_rank(), dist.get_world_size(), local


def export_state_dict(module: nn.Module) -> dict:
    state = module.state_dict()
    return {key.replace("._orig_mod", ""): value for key, value in state.items()}


def _unwrap(model: nn.Module) -> Decoder:
    if isinstance(model, DistributedDataParallel):
        return model.module
    return model


def _batch(windows: torch.Tensor, cursor: int, batch_size: int, device: torch.device) -> tuple[torch.Tensor, torch.Tensor, int]:
    chosen = []
    for _ in range(batch_size):
        chosen.append(windows[cursor % windows.shape[0]])
        cursor += 1
    batch = torch.stack(chosen).to(device, non_blocking=True)
    return batch[:, :-1], batch[:, 1:], cursor


def run_training(
    config: ModelConfig,
    train_windows: torch.Tensor,
    probe_windows: torch.Tensor | None,
    *,
    max_steps: int,
    batch_size: int,
    lr: float,
    betas: tuple[float, float],
    weight_decay: float,
    reserve_bytes: int,
    checkpoint_dir: Path,
    repo_root: Path,
    compile_blocks: bool,
    activation_checkpoint: bool,
    seed: int,
    log_every: int,
    checkpoint_every: int,
    resume: Path | None,
    optimizer_kind: str,
    muon_lr: float,
    muon_momentum: float,
    muon_weight_decay: float,
    changed_windows: torch.Tensor | None = None,
    probe_by_repo: dict[str, torch.Tensor] | None = None,
    baseline_path: Path | None = None,
    retention_patience: int = 3,
) -> int:
    problem = checkpoint_dir_problem(checkpoint_dir, repo_root)
    if problem:
        raise RuntimeError(problem)
    if max_steps < 1 or batch_size < 1:
        raise RuntimeError("max_steps and batch_size must be positive")
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is not available. The fused AdamW step runs on the island GPUs.")

    rank, world, local_rank = init_ranks()
    torch.cuda.set_device(local_rank)
    device = torch.device("cuda", local_rank)
    name = torch.cuda.get_device_name(device)
    gpu_problem = island_gpu_problem(name)
    if gpu_problem:
        raise RuntimeError(gpu_problem)

    total = torch.cuda.get_device_properties(device).total_memory
    fraction = memory_fraction(total, reserve_bytes)
    if fraction < 1:
        apply_memory_fraction(fraction, local_rank)

    torch.manual_seed(seed)
    model = Decoder(config)
    model.activation_checkpoint = activation_checkpoint
    if resume is not None:
        loaded = torch.load(resume, map_location="cpu", weights_only=True)
        model.load_state_dict(loaded["model"])
        start_step = int(loaded["step"])
    else:
        loaded = None
        start_step = 0
    if compile_blocks:
        model.compile_blocks()
    model = model.to(device=device, dtype=torch.bfloat16)
    if world > 1:
        model = DistributedDataParallel(model, device_ids=[local_rank], output_device=local_rank)
    raw = _unwrap(model)
    optimizers = build_optimizers(
        raw,
        optimizer_kind,
        adamw_lr=lr,
        betas=betas,
        adamw_weight_decay=weight_decay,
        muon_lr=muon_lr,
        muon_momentum=muon_momentum,
        muon_weight_decay=muon_weight_decay,
        use_cuda=True,
    )
    if loaded is not None:
        _load_optimizers(optimizers, loaded, optimizer_kind)

    train_local = rank_slice(train_windows, rank, world)
    probe_local = None if probe_windows is None else rank_slice(probe_windows, rank, world)
    cursor = start_step * batch_size
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    log_path = checkpoint_dir / "train.jsonl"
    baseline: dict[str, float] = {}
    if baseline_path is not None and baseline_path.is_file():
        baseline = {key: float(value) for key, value in json.loads(baseline_path.read_text(encoding="utf-8")).items()}
    retained_history: list[float] = []

    for step in range(start_step + 1, start_step + 1 + max_steps):
        model.train()
        for opt in optimizers:
            opt.zero_grad(set_to_none=True)
        inputs, labels, cursor = _batch(train_local, cursor, batch_size, device)
        with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
            loss = model(inputs, labels)
        loss.backward()
        for opt in optimizers:
            opt.step()
        last_step = start_step + max_steps
        do_log = step % log_every == 0 or step == last_step
        probe_loss = None
        if do_log and probe_local is not None and probe_by_repo is None:
            probe_loss = _probe_loss(raw, probe_local, batch_size, device)
        retained: dict[str, float] | None = None
        learned = None
        if do_log and probe_by_repo is not None:
            retained = {
                repo: _probe_loss(raw, windows, batch_size, device) for repo, windows in probe_by_repo.items()
            }
        if do_log and changed_windows is not None and changed_windows.shape[0] > 0:
            learned = _probe_loss(raw, changed_windows, batch_size, device)
        stop = False
        if rank == 0 and do_log:
            record = {
                "step": step,
                "loss": float(loss.detach().float().cpu()),
                "gpu": name,
                "optimizer": optimizer_kind,
            }
            if probe_loss is not None:
                record["probe_loss"] = probe_loss
            if retained is not None:
                extra = replay_log(learned, retained, baseline)
                record.update(extra)
                baseline = remember_baseline(baseline, retained)
                if baseline_path is not None:
                    baseline_path.write_text(json.dumps(baseline, indent=2) + "\n", encoding="utf-8")
                retained_history.append(sum(retained.values()) / len(retained))
                stop = retention_stopped(retained_history, retention_patience)
                if stop:
                    record["stop"] = "retained loss stopped improving"
            with log_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(record) + "\n")
            print(
                f"step {step} loss {record['loss']:.4f} gpu {name} "
                f"reserve_bytes {reserve_bytes}",
                flush=True,
            )
        if rank == 0 and (step % checkpoint_every == 0 or step == last_step or stop):
            _save(raw, optimizers, optimizer_kind, config, step, checkpoint_dir)
        if world > 1:
            import torch.distributed as dist

            flag = torch.tensor([1 if rank == 0 and stop else 0], device=device)
            dist.broadcast(flag, src=0)
            dist.barrier()
            if int(flag.item()) == 1:
                return 0
        elif stop:
            return 0
    return 0


def _probe_loss(raw: Decoder, windows: torch.Tensor, batch_size: int, device: torch.device) -> float:
    raw.eval()
    losses = []
    cursor = 0
    seen = 0
    limit = min(windows.shape[0], batch_size * 4)
    with torch.no_grad():
        while seen < limit:
            inputs, labels, cursor = _batch(windows, cursor, batch_size, device)
            with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
                loss = raw(inputs, labels)
            losses.append(float(loss.detach().float().cpu()))
            seen += batch_size
    raw.train()
    return sum(losses) / len(losses)


def _load_optimizers(optimizers: list[torch.optim.Optimizer], loaded: dict, kind: str) -> None:
    saved_kind = str(loaded.get("optimizer_kind", "adamw"))
    if saved_kind != kind:
        raise RuntimeError(
            f"checkpoint optimizer is {saved_kind} and this run is {kind}. "
            "Resume with the same --optimizer."
        )
    states = loaded.get("optimizers")
    if states is None:
        states = [loaded["optimizer"]]
    if len(states) != len(optimizers):
        raise RuntimeError("checkpoint optimizer count does not match this run")
    for opt, state in zip(optimizers, states):
        opt.load_state_dict(state)


def _save(
    raw: Decoder,
    optimizers: list[torch.optim.Optimizer],
    kind: str,
    config: ModelConfig,
    step: int,
    checkpoint_dir: Path,
) -> None:
    path = checkpoint_dir / f"step-{step:08d}.pt"
    torch.save(
        {
            "step": step,
            "model": export_state_dict(raw),
            "optimizer_kind": kind,
            "optimizers": [opt.state_dict() for opt in optimizers],
            "config": asdict(config),
        },
        path,
    )
    print(f"checkpoint {path}", flush=True)
