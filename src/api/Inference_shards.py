"""TCP / coordinator-derived preflight for 27B RPC pool shards.

Prefer ``inference-shards.active.env`` (core + opted-in gaming from Start-Stop)
when present, else ``inference-shards.env`` (always-on core). Gaming catalog:
``inference-shards.gaming.env``. Docs: docs/inference_GAMING_HOST_JOIN.md,
docs/ADMIN_HEALTH_WEB_WORKFLOW.md.
"""

from __future__ import annotations

import os
import socket
from pathlib import Path
from typing import Any

# Always-on core fallback when no shards file is mounted (matches inference-shards.env).
_DEFAULT_SHARDS: tuple[tuple[str, int], ...] = (
    ("orchestrator", 31356),
    ("orchestrator", 31357),
    ("orchestrator", 31350),
    ("hub", 31353),
)


def _llamacpp_dir() -> Path:
    for candidate in (
        Path("/app/deploy/llamacpp-rpc"),
        Path(__file__).resolve().parents[2] / "deploy" / "llamacpp-rpc",
    ):
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parents[2] / "deploy" / "llamacpp-rpc"


def _repo_inference_shards_path() -> Path:
    """Active membership file if present, else core-only inference-shards.env."""
    override = (os.getenv("ALFA_inference_SHARDS_FILE") or "").strip()
    if override:
        return Path(override)
    llc = _llamacpp_dir()
    active = llc / "inference-shards.active.env"
    if active.is_file():
        return active
    core = llc / "inference-shards.env"
    if core.is_file():
        return core
    return Path(__file__).resolve().parents[2] / "deploy" / "llamacpp-rpc" / "inference-shards.env"


def _parse_shards_file(path: Path) -> list[tuple[str, int]]:
    if not path.is_file():
        return []
    out: list[tuple[str, int]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        host, port_s = parts[0], parts[1]
        try:
            out.append((host, int(port_s)))
        except ValueError:
            continue
    return out


def parse_inference_catalog_endpoints() -> list[tuple[str, int, str]]:
    """Core + gaming catalog for admin health inventory (host, port, label).

    Label is the optional 4th field from gaming.env or ``core`` / host for core rows.
    Does not imply the shard is in the live TENSOR_SPLIT -- use active.env for that.
    """
    llc = _llamacpp_dir()
    seen: set[tuple[str, int]] = set()
    rows: list[tuple[str, int, str]] = []

    def add(host: str, port: int, label: str) -> None:
        key = (host, port)
        if key in seen:
            return
        seen.add(key)
        rows.append((host, port, label))

    for host, port in _parse_shards_file(llc / "inference-shards.env") or list(_DEFAULT_SHARDS):
        add(host, port, "core")

    gaming = llc / "inference-shards.gaming.env"
    if gaming.is_file():
        for line in gaming.read_text(encoding="utf-8").splitlines():
            raw = line.split("#", 1)[0].strip()
            if not raw:
                continue
            parts = raw.split()
            if len(parts) < 2:
                continue
            host, port_s = parts[0], parts[1]
            try:
                port = int(port_s)
            except ValueError:
                continue
            label = f"opt-in-{host.split('.')[-1]}"
            # Format: HOST PORT VRAM_GB LABEL [MODEL_PCT]
            if len(parts) >= 4:
                label = parts[3]
            add(host, port, label)

    return rows


def parse_inference_shard_endpoints() -> list[tuple[str, int]]:
    """Return (host, port) pairs from env override or inference-shards.env."""
    raw_eps = (os.getenv("ALFA_inference_SHARD_ENDPOINTS") or "").strip()
    if raw_eps:
        out: list[tuple[str, int]] = []
        for part in raw_eps.split(","):
            part = part.strip()
            if not part:
                continue
            if ":" not in part:
                continue
            host, port_s = part.rsplit(":", 1)
            try:
                out.append((host.strip(), int(port_s.strip())))
            except ValueError:
                continue
        if out:
            return out

    path = _repo_inference_shards_path()
    return _parse_shards_file(path) or list(_DEFAULT_SHARDS)


def _tcp_reachable(host: str, port: int, *, timeout_sec: float = 3.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout_sec):
            return True
    except OSError:
        return False


def check_inference_shards(*, timeout_sec: float = 3.0) -> dict[str, Any]:
    """Probe every inference GPU shard port. Used by picker active state and admin health."""
    endpoints = parse_inference_shard_endpoints()
    shards: list[dict[str, Any]] = []
    all_ok = True
    for host, port in endpoints:
        ok = _tcp_reachable(host, port, timeout_sec=timeout_sec)
        shards.append({"host": host, "port": port, "ok": ok})
        if not ok:
            all_ok = False
    return {
        "name": "inference-shards",
        "ok": all_ok,
        "shards": shards,
        "count": len(shards),
    }
