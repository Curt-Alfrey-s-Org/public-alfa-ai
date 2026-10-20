"""bf16 matmul and Muon import check for the PyTorch 2.14 cu130 wheel.

Official index: https://download.pytorch.org/whl/cu130
Muon: https://docs.pytorch.org/docs/2.14/generated/torch.optim.Muon.html
matmul: https://docs.pytorch.org/docs/stable/generated/torch.matmul.html

The wheel is seeded on hub at /mnt/hub/alfa-ai/wheels/torch-cu130.
Do not download it on a trainer host.
"""

from __future__ import annotations

import sys


def wheel_problem(version: str, cuda: str | None) -> str | None:
    if not version.startswith("2.14"):
        return f"torch {version} is not 2.14"
    if cuda is None or not str(cuda).startswith("13.0"):
        return f"torch.version.cuda {cuda} is not 13.0"
    return None


def main() -> int:
    try:
        import torch
    except ImportError:
        print(
            "FAIL torch is not installed. Seed the 2.14 cu130 wheel on hub "
            "at /mnt/hub/alfa-ai/wheels/torch-cu130, then install from that directory.",
            file=sys.stderr,
        )
        return 1

    problem = wheel_problem(torch.__version__, getattr(torch.version, "cuda", None))
    if problem:
        print(f"FAIL {problem}", file=sys.stderr)
        return 1
    if not torch.cuda.is_available():
        print("FAIL cuda device is not available", file=sys.stderr)
        return 1

    device = torch.device("cuda", 0)
    name = torch.cuda.get_device_name(device)
    major, minor = torch.cuda.get_device_capability(device)
    left = torch.randn(256, 256, device=device, dtype=torch.bfloat16)
    right = torch.randn(256, 256, device=device, dtype=torch.bfloat16)
    product = torch.matmul(left, right)
    torch.cuda.synchronize(device)
    if product.dtype != torch.bfloat16 or product.shape != (256, 256):
        print(f"FAIL matmul dtype={product.dtype} shape={tuple(product.shape)}", file=sys.stderr)
        return 1
    if not torch.isfinite(product).all().item():
        print("FAIL bf16 matmul produced a non-finite value", file=sys.stderr)
        return 1

    try:
        muon = torch.optim.Muon
    except AttributeError:
        print("FAIL torch.optim.Muon is missing from this wheel", file=sys.stderr)
        return 1
    weight = torch.nn.Parameter(torch.randn(8, 8))
    muon([weight], lr=0.001)

    print(f"PASS torch {torch.__version__} cuda {torch.version.cuda}")
    print(f"PASS gpu {name} cap {major}.{minor}")
    print("PASS bf16 matmul 256x256")
    print("PASS torch.optim.Muon")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
