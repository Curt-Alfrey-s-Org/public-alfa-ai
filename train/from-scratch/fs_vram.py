"""Leave desktop VRAM unused on the Windows island hosts.

The cap is torch.cuda.memory.set_per_process_memory_fraction. Allowed memory
is total visible memory times the fraction.
https://docs.pytorch.org/docs/2.14/generated/torch.cuda.memory.set_per_process_memory_fraction.html

orchestrator, gaming-c, and gaming-b keep 3 GiB for the Win11 desktop. inference is headless.
"""

from __future__ import annotations

GIB = 1024 ** 3
DESKTOP_RESERVE_BYTES = 3 * GIB
DESKTOP_HOSTS = frozenset({"orchestrator", "gaming-c", "gaming-b"})
HEADLESS_HOSTS = frozenset({"inference"})


def memory_fraction(total_bytes: int, reserve_bytes: int) -> float:
    if total_bytes < 1:
        raise ValueError("total_bytes must be positive")
    if reserve_bytes < 0:
        raise ValueError("reserve_bytes must be zero or positive")
    if reserve_bytes >= total_bytes:
        raise ValueError("desktop reserve does not fit on this GPU")
    if reserve_bytes == 0:
        return 1.0
    return (total_bytes - reserve_bytes) / total_bytes


def reserve_bytes_for_host(host: str | None, override_gb: float | None) -> int:
    """override_gb wins. Otherwise a confirmed host selects 3 GiB or zero.

    An unconfirmed host with no override must not guess.
    """
    if override_gb is not None:
        if override_gb < 0:
            raise ValueError("desktop reserve cannot be negative")
        return int(override_gb * GIB)
    if host in DESKTOP_HOSTS:
        return DESKTOP_RESERVE_BYTES
    if host in HEADLESS_HOSTS:
        return 0
    raise ValueError(
        "host is not a confirmed island desktop or the headless inference. "
        "Pass --desktop-reserve-gb 3 on orchestrator, gaming-c, and gaming-b, and 0 on inference."
    )


def apply_memory_fraction(fraction: float, device: int = 0) -> None:
    if not 0 < fraction <= 1:
        raise ValueError(f"memory fraction {fraction} is outside (0, 1]")
    import torch

    torch.cuda.memory.set_per_process_memory_fraction(fraction, device)
