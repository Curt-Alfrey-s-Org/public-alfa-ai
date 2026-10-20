"""Single-island trainer pieces that do not need a GPU."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
import torch
import torch.nn.functional as F

_PKG = Path(__file__).resolve().parents[1] / "train" / "from-scratch"
sys.path.insert(0, str(_PKG))

from fs_data import rank_slice  # noqa: E402
from fs_gpu import island_gpu_problem  # noqa: E402
from fs_loss import chunked_cross_entropy  # noqa: E402
from fs_model import Decoder, ModelConfig, adamw_kwargs, count_parameters  # noqa: E402
from fs_optim import split_parameters  # noqa: E402
from fs_replay import (  # noqa: E402
    changed_paths,
    forgetting,
    git_changed_paths,
    remember_baseline,
    replay_log,
    replay_windows,
    retention_stopped,
)
from fs_train import checkpoint_dir_problem, export_state_dict  # noqa: E402
from fs_vram import memory_fraction, reserve_bytes_for_host  # noqa: E402


def test_parameter_count_matches_the_module() -> None:
    config = ModelConfig(vocab_size=48, n_layer=2, n_embd=32, n_head=4, seq_len=16, mlp_mult=4)
    model = Decoder(config)
    assert count_parameters(config) == sum(parameter.numel() for parameter in model.parameters())
    tied = [parameter for parameter in model.parameters() if parameter.shape[0] == config.vocab_size]
    assert len(tied) == 1
    assert count_parameters(ModelConfig(vocab_size=151936)) > count_parameters(ModelConfig(vocab_size=32768))


def test_embedding_is_tied_by_using_it_for_the_loss() -> None:
    config = ModelConfig(vocab_size=48, n_layer=1, n_embd=32, n_head=4, seq_len=8, mlp_mult=2)
    model = Decoder(config)
    before = model.tok_embed.weight.detach().clone()
    tokens = torch.randint(0, config.vocab_size, (2, 8))
    loss = model(tokens[:, :-1], tokens[:, 1:])
    loss.backward()
    assert model.tok_embed.weight.grad is not None
    assert not torch.equal(model.tok_embed.weight.grad, torch.zeros_like(before))
    model.zero_grad(set_to_none=True)
    model.activation_checkpoint = True
    again = model(tokens[:, :-1], tokens[:, 1:])
    again.backward()
    assert model.tok_embed.weight.grad is not None


def test_chunked_cross_entropy_matches_full_logits() -> None:
    hidden = torch.randn(5, 8)
    weight = torch.randn(17, 8)
    targets = torch.randint(0, 17, (5,))
    chunked = chunked_cross_entropy(hidden, weight, targets, vocab_chunk=4)
    full = F.cross_entropy(hidden @ weight.T, targets)
    assert torch.allclose(chunked, full, rtol=1e-5, atol=1e-5)


def test_island_gpu_names() -> None:
    assert island_gpu_problem("NVIDIA GeForce RTX 3060") is None
    assert island_gpu_problem("NVIDIA GeForce RTX 5070") is None
    assert island_gpu_problem("NVIDIA GeForce RTX 5060") is not None
    assert island_gpu_problem("NVIDIA GeForce RTX 3050") is not None


def test_desktop_reserve_leaves_3_gib_on_windows_hosts() -> None:
    total = 12 * 1024**3
    fraction = memory_fraction(total, 3 * 1024**3)
    assert fraction == pytest.approx((12 - 3) / 12)
    assert reserve_bytes_for_host("orchestrator", None) == 3 * 1024**3
    assert reserve_bytes_for_host("gaming-c", None) == 3 * 1024**3
    assert reserve_bytes_for_host("gaming-b", None) == 3 * 1024**3
    assert reserve_bytes_for_host("inference", None) == 0
    assert reserve_bytes_for_host(None, 0) == 0
    with pytest.raises(ValueError):
        reserve_bytes_for_host(None, None)


def test_rank_slice_covers_every_window_once() -> None:
    windows = torch.arange(10).view(10, 1)
    parts = [rank_slice(windows, rank, 4) for rank in range(4)]
    flat = torch.cat(parts).flatten()
    assert torch.equal(torch.sort(flat).values, torch.arange(10))


def test_checkpoints_are_not_written_inside_the_repo() -> None:
    repo = Path(__file__).resolve().parents[1]
    assert checkpoint_dir_problem(repo / "train" / "from-scratch", repo) is not None
    assert checkpoint_dir_problem(Path("/mnt/hub/alfa-ai/training/alfa-train/checkpoints"), repo) is None


def test_fused_adamw_is_cuda_only() -> None:
    assert adamw_kwargs(True) == {"fused": True}
    with pytest.raises(RuntimeError):
        adamw_kwargs(False)


def test_muon_keeps_the_embedding_on_adamw() -> None:
    config = ModelConfig(vocab_size=48, n_layer=1, n_embd=32, n_head=4, seq_len=8, mlp_mult=2)
    model = Decoder(config)
    muon_params, adam_params = split_parameters(model)
    assert all(param.ndim == 2 for param in muon_params)
    assert any(param is model.tok_embed.weight for param in adam_params)
    assert all(param is not model.tok_embed.weight for param in muon_params)
    seen = {id(param) for param in muon_params + adam_params}
    assert seen == {id(param) for param in model.parameters() if param.requires_grad}
    tokens = torch.randint(0, config.vocab_size, (2, 8))
    loss = model(tokens[:, :-1], tokens[:, 1:])
    loss.backward()
    muon = torch.optim.Muon(muon_params, lr=0.02, momentum=0.95, adjust_lr_fn="original")
    adam = torch.optim.AdamW(adam_params, lr=3e-4, weight_decay=0.1)
    muon.step()
    adam.step()


def test_compiled_prefix_is_stripped_from_checkpoints() -> None:
    config = ModelConfig(vocab_size=32, n_layer=1, n_embd=16, n_head=4, seq_len=4, mlp_mult=2)
    model = Decoder(config)
    state = export_state_dict(model)
    state = {f"blocks.0._orig_mod.{key[9:]}": value for key, value in state.items() if key.startswith("blocks.0.")}
    cleaned = {key.replace("._orig_mod", ""): value for key, value in state.items()}
    assert all("._orig_mod" not in key for key in cleaned)
    model.load_state_dict(cleaned, strict=False)


def test_replay_keeps_the_old_corpus_in_the_majority() -> None:
    old = torch.arange(20).view(10, 2)
    changed = torch.arange(4).view(2, 2)
    mixed = replay_windows(old, changed, upsample=2)
    assert mixed.shape == (14, 2)
    assert torch.equal(mixed[:10], old)
    assert torch.equal(mixed[10:12], changed)
    assert torch.equal(mixed[12:14], changed)
    with pytest.raises(ValueError):
        replay_windows(old[:4], changed, upsample=2)


def test_changed_paths_ignore_unchanged_and_removed_files() -> None:
    old = {"a.py": "one", "b.py": "same", "gone.py": "old"}
    new = {"a.py": "two", "b.py": "same", "c.py": "new"}
    assert changed_paths(old, new) == ["a.py", "c.py"]


def test_forgetting_is_the_rise_in_retained_loss() -> None:
    assert forgetting(1.4, 1.1) == pytest.approx(0.3)
    baseline = remember_baseline({}, {"alfa-ai": 1.1})
    baseline = remember_baseline(baseline, {"alfa-ai": 9.0, "atems": 2.0})
    assert baseline["alfa-ai"] == 1.1
    assert baseline["atems"] == 2.0
    record = replay_log(0.5, {"alfa-ai": 1.4, "atems": 2.0}, {"alfa-ai": 1.1})
    assert record["rewarm"] is False
    assert record["forgetting"] == {"alfa-ai": pytest.approx(0.3)}
    assert "atems" not in record["forgetting"]


def test_retention_stop_waits_for_patience() -> None:
    assert retention_stopped([1.0, 0.9], 3) is False
    assert retention_stopped([1.0, 0.8, 0.81, 0.82, 0.83], 3) is True
    assert retention_stopped([1.0, 0.8, 0.81, 0.82, 0.7], 3) is False


def test_git_changed_paths_lists_a_later_edit(tmp_path: Path) -> None:
    import os
    import subprocess

    repo = tmp_path / "repo"
    repo.mkdir()
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "replay-test",
        "GIT_AUTHOR_EMAIL": "operator@example.com",
        "GIT_COMMITTER_NAME": "replay-test",
        "GIT_COMMITTER_EMAIL": "operator@example.com",
    }
    subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True, env=env)
    (repo / "a.py").write_text("one\n", encoding="utf-8")
    subprocess.run(["git", "add", "a.py"], cwd=repo, check=True, capture_output=True, env=env)
    subprocess.run(["git", "commit", "-m", "first"], cwd=repo, check=True, capture_output=True, env=env)
    sha = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True, env=env
    ).stdout.strip()
    (repo / "a.py").write_text("two\n", encoding="utf-8")
    (repo / "b.py").write_text("new\n", encoding="utf-8")
    subprocess.run(["git", "add", "a.py", "b.py"], cwd=repo, check=True, capture_output=True, env=env)
    subprocess.run(["git", "commit", "-m", "second"], cwd=repo, check=True, capture_output=True, env=env)
    assert git_changed_paths(repo, sha) == ["a.py", "b.py"]
