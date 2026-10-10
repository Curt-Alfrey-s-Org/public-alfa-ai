"""410M-class decoder for the single-island trainer.

Architecture pieces named in docs/FROM_SCRATCH_TRAINER_PLAN.md: RoPE, QK-norm,
ReLU squared, tied embeddings. Attention is SDPA. Each block can be compiled
on its own. The whole DDP step is not compiled.

RoPE base 10000: https://arxiv.org/abs/2104.09864
SDPA: https://docs.pytorch.org/docs/2.14/generated/torch.nn.functional.scaled_dot_product_attention.html
RMSNorm: https://docs.pytorch.org/docs/2.14/generated/torch.nn.RMSNorm.html
torch.compile: https://docs.pytorch.org/docs/2.14/generated/torch.compile.html
"""

from __future__ import annotations

from dataclasses import dataclass

import torch
from torch import nn
import torch.nn.functional as F

from fs_loss import chunked_cross_entropy


@dataclass(frozen=True)
class ModelConfig:
    vocab_size: int
    n_layer: int = 24
    n_embd: int = 1024
    n_head: int = 16
    seq_len: int = 2048
    mlp_mult: int = 4
    rope_theta: float = 10000.0
    init_std: float = 0.02

    def __post_init__(self) -> None:
        if self.vocab_size < 1:
            raise ValueError("vocab_size must be positive")
        if self.n_embd % self.n_head != 0:
            raise ValueError("n_embd must divide evenly by n_head")
        if self.n_layer < 1 or self.seq_len < 2 or self.mlp_mult < 1:
            raise ValueError("n_layer, seq_len, and mlp_mult must be usable")

    @property
    def head_dim(self) -> int:
        return self.n_embd // self.n_head

    @property
    def mlp_hidden(self) -> int:
        return self.n_embd * self.mlp_mult


def count_parameters(config: ModelConfig) -> int:
    """Tied embedding is counted once."""
    embed = config.vocab_size * config.n_embd
    per_layer_attn = 4 * config.n_embd * config.n_embd
    per_layer_mlp = 2 * config.n_embd * config.mlp_hidden
    per_layer_norm = 2 * config.n_embd + 2 * config.head_dim
    return embed + config.n_layer * (per_layer_attn + per_layer_mlp + per_layer_norm) + config.n_embd


class CausalSelfAttention(nn.Module):
    def __init__(self, config: ModelConfig) -> None:
        super().__init__()
        self.n_head = config.n_head
        self.head_dim = config.head_dim
        self.qkv = nn.Linear(config.n_embd, 3 * config.n_embd, bias=False)
        self.out = nn.Linear(config.n_embd, config.n_embd, bias=False)
        self.q_norm = nn.RMSNorm(self.head_dim)
        self.k_norm = nn.RMSNorm(self.head_dim)
        inv_freq = 1.0 / (
            config.rope_theta
            ** (torch.arange(0, self.head_dim, 2, dtype=torch.float32) / self.head_dim)
        )
        self.register_buffer("inv_freq", inv_freq, persistent=False)

    def _rope(self, states: torch.Tensor) -> torch.Tensor:
        # states: [B, heads, T, head_dim]
        seq_len = states.shape[-2]
        positions = torch.arange(seq_len, device=states.device, dtype=torch.float32)
        freqs = torch.outer(positions, self.inv_freq.to(dtype=torch.float32))
        cos = torch.cos(freqs).to(dtype=states.dtype)
        sin = torch.sin(freqs).to(dtype=states.dtype)
        cos = torch.cat((cos, cos), dim=-1)[None, None, :, :]
        sin = torch.cat((sin, sin), dim=-1)[None, None, :, :]
        half = self.head_dim // 2
        rotated = torch.cat((-states[..., half:], states[..., :half]), dim=-1)
        return states * cos + rotated * sin

    def forward(self, hidden: torch.Tensor) -> torch.Tensor:
        batch, seq_len, _channels = hidden.shape
        qkv = self.qkv(hidden).view(batch, seq_len, 3, self.n_head, self.head_dim)
        q, k, v = qkv.unbind(dim=2)
        q = self.q_norm(q).transpose(1, 2)
        k = self.k_norm(k).transpose(1, 2)
        v = v.transpose(1, 2)
        q = self._rope(q)
        k = self._rope(k)
        attended = F.scaled_dot_product_attention(q, k, v, is_causal=True, dropout_p=0.0)
        attended = attended.transpose(1, 2).contiguous().view(batch, seq_len, -1)
        return self.out(attended)


class ReluSquaredMlp(nn.Module):
    def __init__(self, config: ModelConfig) -> None:
        super().__init__()
        self.up = nn.Linear(config.n_embd, config.mlp_hidden, bias=False)
        self.down = nn.Linear(config.mlp_hidden, config.n_embd, bias=False)

    def forward(self, hidden: torch.Tensor) -> torch.Tensor:
        return self.down(F.relu(self.up(hidden)).square())


class Block(nn.Module):
    def __init__(self, config: ModelConfig) -> None:
        super().__init__()
        self.norm_1 = nn.RMSNorm(config.n_embd)
        self.attn = CausalSelfAttention(config)
        self.norm_2 = nn.RMSNorm(config.n_embd)
        self.mlp = ReluSquaredMlp(config)

    def forward(self, hidden: torch.Tensor) -> torch.Tensor:
        hidden = hidden + self.attn(self.norm_1(hidden))
        hidden = hidden + self.mlp(self.norm_2(hidden))
        return hidden


class Decoder(nn.Module):
    """Returns hidden states, not logits. The loss reads the tied embedding."""

    def __init__(self, config: ModelConfig) -> None:
        super().__init__()
        self.config = config
        self.tok_embed = nn.Embedding(config.vocab_size, config.n_embd)
        self.blocks = nn.ModuleList(Block(config) for _ in range(config.n_layer))
        self.norm = nn.RMSNorm(config.n_embd)
        self.activation_checkpoint = False
        self.reset_parameters()

    def reset_parameters(self) -> None:
        nn.init.normal_(self.tok_embed.weight, mean=0.0, std=self.config.init_std)
        for module in self.modules():
            if isinstance(module, nn.Linear):
                nn.init.normal_(module.weight, mean=0.0, std=self.config.init_std)

    def forward(self, token_ids: torch.Tensor, labels: torch.Tensor | None = None) -> torch.Tensor:
        if token_ids.size(-1) > self.config.seq_len:
            raise ValueError(f"sequence {token_ids.size(-1)} is longer than {self.config.seq_len}")
        hidden = self.tok_embed(token_ids)
        for block in self.blocks:
            if self.activation_checkpoint and self.training:
                hidden = torch.utils.checkpoint.checkpoint(block, hidden, use_reentrant=False)
            else:
                hidden = block(hidden)
        hidden = self.norm(hidden)
        if labels is None:
            return hidden
        return chunked_cross_entropy(hidden, self.tok_embed.weight, labels)

    def compile_blocks(self) -> None:
        """Compile each block. Do not compile this module under DDP."""
        for index, block in enumerate(self.blocks):
            self.blocks[index] = torch.compile(block)


def adamw_kwargs(use_cuda: bool) -> dict:
    """Fused AdamW is the CUDA optimizer for this step.

    https://docs.pytorch.org/docs/2.14/generated/torch.optim.AdamW.html
    """
    if not use_cuda:
        raise RuntimeError("fused AdamW requires CUDA. This step does not fall back to foreach.")
    return {"fused": True}
