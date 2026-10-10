"""Side-process heartbeat files for Admin Missions fleet visibility."""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


def audit_log_dir() -> Path:
    raw = os.getenv(
        "ALFA_AI_AUDIT_LOG_DIR",
        "/mnt/hub/alfa-ai/agent-audit-logs",
    ).strip()
    return Path(raw)


def heartbeat_path(log_dir: Path, name: str) -> Path:
    return log_dir / "heartbeats" / f"{name}.json"


def write_heartbeat(
    log_dir: Path | str,
    name: str,
    *,
    status: str = "alive",
    last_action: str = "",
    pid: int | None = None,
) -> Path:
    """Write or update a side-process heartbeat JSON file."""
    root = Path(log_dir)
    root.mkdir(parents=True, exist_ok=True)
    hb_dir = root / "heartbeats"
    hb_dir.mkdir(parents=True, exist_ok=True)
    payload: dict[str, Any] = {
        "name": name,
        "updated_at": datetime.now(tz=UTC).isoformat(),
        "last_action": last_action,
        "status": status,
    }
    if pid is not None:
        payload["pid"] = pid
    else:
        payload["pid"] = os.getpid()
    path = heartbeat_path(root, name)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2), encoding="utf-8")
    return path


def read_heartbeat(log_dir: Path, name: str) -> dict[str, Any] | None:
    path = heartbeat_path(log_dir, name)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    return data if isinstance(data, dict) else None
