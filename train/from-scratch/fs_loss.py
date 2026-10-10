"""fp32 cross-entropy in vocab chunks.

The full [tokens, vocab] logit tensor is not materialized. bf16 cross-entropy
stays off until it matches this fp32 reduction
(docs/FROM_SCRATCH_TRAINER_PLAN.md).
"""

from __future__ import annotations

import torch


def chunked_cross_entropy(
    hidden: torch.Tensor,
    weight: torch.Tensor,
    targets: torch.Tensor,
    vocab_chunk: int = 4096,
) -> torch.Tensor:
    """Mean next-token loss. hidden is [N, H] or [B, T, H]. weight is [V, H]."""
    if hidden.ndim == 3:
        hidden = hidden.reshape(-1, hidden.shape[-1])
        targets = targets.reshape(-1)
    if hidden.ndim != 2:
        raise ValueError("hidden must be [N, H] or [B, T, H]")
    if weight.ndim != 2 or weight.shape[1] != hidden.shape[1]:
        raise ValueError("weight must be [vocab, hidden]")
    if targets.shape != hidden.shape[:1]:
        raise ValueError("targets must match the token count of hidden")
    if vocab_chunk < 1:
        raise ValueError("vocab_chunk must be positive")

    vocab = weight.shape[0]
    if int(targets.min()) < 0 or int(targets.max()) >= vocab:
        raise ValueError("target id is outside the embedding vocab")

    hidden_f = hidden.float()
    count = hidden_f.shape[0]
    running_max = torch.full((count,), torch.finfo(torch.float32).min, device=hidden.device)
    running_sum = torch.zeros(count, device=hidden.device, dtype=torch.float32)
    target_logit = torch.zeros(count, device=hidden.device, dtype=torch.float32)

    for start in range(0, vocab, vocab_chunk):
        end = min(start + vocab_chunk, vocab)
        logits = hidden_f @ weight[start:end].float().T
        chunk_max = logits.max(dim=-1).values
        new_max = torch.maximum(running_max, chunk_max)
        running_sum = running_sum * torch.exp(running_max - new_max) + torch.exp(
            logits - new_max.unsqueeze(-1)
        ).sum(dim=-1)
        running_max = new_max
        in_chunk = (targets >= start) & (targets < end)
        if bool(in_chunk.any()):
            local = targets[in_chunk] - start
            target_logit[in_chunk] = logits[in_chunk, local]

    log_z = running_max + torch.log(running_sum)
    return (log_z - target_logit).mean()
