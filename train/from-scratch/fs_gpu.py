"""Which hosts have RTX 5070s and RTX 3060s.

The hardware table in docs/NODE_INVENTORY.md is the inventory. A host is
confirmed only when this machine's hostname matches that row and nvidia-smi
lists the same RTX models. A name match on the GPU alone is not a host match:
orchestrator and inference can both report a 3060.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass

_RTX = re.compile(r"RTX\s*(\d{4})", re.IGNORECASE)


@dataclass(frozen=True)
class InventoryGpuRow:
    host: str
    aliases: tuple[str, ...]
    rtx_models: tuple[str, ...]


def _cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def _aliases(node_cell: str) -> tuple[str, ...]:
    raw = node_cell.replace("**", "")
    found: set[str] = set()
    found.update(re.findall(r"`([^`]+)`", raw))
    found.update(re.findall(r"\(([^)]+)\)", raw))
    plain = raw.replace("`", " ")
    found.update(re.findall(r"[A-Za-z0-9][A-Za-z0-9._-]*", plain))
    return tuple(sorted({item.casefold() for item in found if item}))


def _host_label(node_cell: str) -> str | None:
    match = re.search(r"`(\.\d+)`", node_cell)
    if match:
        return match.group(1)
    return None


def parse_hardware_table(text: str) -> list[InventoryGpuRow]:
    """Parse the Node/GPU table under ``### Hardware``.

    The April summary table earlier in the file names hosts in prose. The
    hardware table is the one that puts ``gaming-c`` / ``orchestrator`` in the Node column.
    """
    lines = text.splitlines()
    start = 0
    for index, line in enumerate(lines):
        if line.strip().casefold() == "### hardware":
            start = index + 1
            break
    header_index = None
    gpu_column = None
    for index, line in enumerate(lines[start:], start):
        if not line.startswith("|"):
            continue
        cells = _cells(line)
        lowered = [cell.casefold().strip("* ") for cell in cells]
        if "node" in lowered and "gpu" in lowered:
            header_index = index
            gpu_column = lowered.index("gpu")
            break
    if header_index is None or gpu_column is None:
        raise ValueError("NODE_INVENTORY.md has no Node/GPU hardware table")

    rows: list[InventoryGpuRow] = []
    for line in lines[header_index + 2 :]:
        if not line.startswith("|"):
            break
        cells = _cells(line)
        if len(cells) <= gpu_column:
            continue
        host = _host_label(cells[0])
        if not host:
            continue
        models = tuple(_RTX.findall(cells[gpu_column]))
        rows.append(InventoryGpuRow(host=host, aliases=_aliases(cells[0]), rtx_models=models))
    return rows


def island_from_rows(rows: list[InventoryGpuRow]) -> dict[str, list[str]]:
    """Inventory roles only. 5060 and 3050 are not 5070 or 3060."""
    grouped = {"5070": [], "3060": []}
    for row in rows:
        if "5070" in row.rtx_models and row.host not in grouped["5070"]:
            grouped["5070"].append(row.host)
        if "3060" in row.rtx_models and row.host not in grouped["3060"]:
            grouped["3060"].append(row.host)
    return grouped


def parse_nvidia_smi_csv(text: str) -> list[str]:
    """Parse `nvidia-smi --query-gpu=name --format=csv,noheader` output."""
    names: list[str] = []
    for line in text.splitlines():
        name = line.strip()
        if not name or name.lower().startswith("name"):
            continue
        names.append(name)
    return names


def query_nvidia_smi() -> tuple[list[str], str | None]:
    """Return (gpu names, error). Empty names and an error means the query failed."""
    try:
        proc = subprocess.run(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        return [], str(exc)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip() or f"exit {proc.returncode}"
        return [], err
    return parse_nvidia_smi_csv(proc.stdout or ""), None


def island_gpu_problem(name: str) -> str | None:
    """The island is the 5070s and the 3060s. The 5060 on inference stays out."""
    lowered = name.casefold()
    if "5060" in lowered:
        return (
            f"visible GPU {name} is an RTX 5060. On inference set CUDA_VISIBLE_DEVICES "
            "to the RTX 3060 before launch."
        )
    if "5070" not in lowered and "3060" not in lowered:
        return f"visible GPU {name} is not an island RTX 5070 or RTX 3060"
    return None


def confirm_local(
    rows: list[InventoryGpuRow],
    hostname: str,
    smi_names: list[str],
) -> dict:
    """Confirm a host only when hostname and nvidia-smi agree with one inventory row."""
    needle = hostname.casefold().strip()
    matches = [row for row in rows if needle and needle in row.aliases]
    smi_models = tuple(model for name in smi_names for model in _RTX.findall(name))
    if len(matches) != 1:
        return {
            "confirmed": False,
            "host": None,
            "reason": "hostname_not_unique" if len(matches) > 1 else "hostname_not_in_inventory",
            "smi_models": list(smi_models),
        }
    row = matches[0]
    if not smi_models or tuple(sorted(smi_models)) != tuple(sorted(row.rtx_models)):
        return {
            "confirmed": False,
            "host": row.host,
            "reason": "nvidia_smi_models_differ_from_inventory",
            "inventory_models": list(row.rtx_models),
            "smi_models": list(smi_models),
        }
    roles = [model for model in row.rtx_models if model in {"5070", "3060"}]
    return {
        "confirmed": True,
        "host": row.host,
        "roles": roles,
        "inventory_models": list(row.rtx_models),
        "smi_models": list(smi_models),
        "smi_names": list(smi_names),
    }
