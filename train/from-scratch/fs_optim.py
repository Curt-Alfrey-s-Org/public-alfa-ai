"""AdamW, or Muon on hidden matrices with fused AdamW on the rest.

Muon is for 2D hidden weights. The tied embedding is 2D and stays on AdamW.
https://docs.pytorch.org/docs/2.14/generated/torch.optim.Muon.html
"""

from __future__ import annotations

import torch
from torch import nn

from fs_model import adamw_kwargs


def _bare(name: str) -> str:
    return name.replace("._orig_mod", "")


def split_parameters(module: nn.Module) -> tuple[list[nn.Parameter], list[nn.Parameter]]:
    """Return (muon hidden matrices, adamw parameters)."""
    muon: list[nn.Parameter] = []
    adamw: list[nn.Parameter] = []
    for name, param in module.named_parameters():
        if not param.requires_grad:
            continue
        if _bare(name) == "tok_embed.weight" or param.ndim != 2:
            adamw.append(param)
        else:
            muon.append(param)
    if not muon:
        raise ValueError("Muon group is empty")
    embed = module.tok_embed.weight
    if not any(param is embed for param in adamw):
        raise ValueError("the tied embedding must stay on AdamW")
    if any(param is embed for param in muon):
        raise ValueError("the tied embedding was placed on Muon")
    return muon, adamw


def build_optimizers(
    module: nn.Module,
    kind: str,
    *,
    adamw_lr: float,
    betas: tuple[float, float],
    adamw_weight_decay: float,
    muon_lr: float,
    muon_momentum: float,
    muon_weight_decay: float,
    use_cuda: bool,
) -> list[torch.optim.Optimizer]:
    if kind == "adamw":
        return [
            torch.optim.AdamW(
                module.parameters(),
                lr=adamw_lr,
                betas=betas,
                weight_decay=adamw_weight_decay,
                **adamw_kwargs(use_cuda),
            )
        ]
    if kind != "muon":
        raise ValueError("optimizer must be adamw or muon")
    try:
        muon_cls = torch.optim.Muon
    except AttributeError as exc:
        raise RuntimeError(
            "torch.optim.Muon is missing from this wheel. "
            "The step-2 check imports it from the cu130 build "
            "(https://docs.pytorch.org/docs/2.14/generated/torch.optim.Muon.html)."
        ) from exc
    muon_params, adam_params = split_parameters(module)
    return [
        muon_cls(
            muon_params,
            lr=muon_lr,
            weight_decay=muon_weight_decay,
            momentum=muon_momentum,
            adjust_lr_fn="original",
        ),
        torch.optim.AdamW(
            adam_params,
            lr=adamw_lr,
            betas=betas,
            weight_decay=adamw_weight_decay,
            **adamw_kwargs(use_cuda),
        ),
    ]
