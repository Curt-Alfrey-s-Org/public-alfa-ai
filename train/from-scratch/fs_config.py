"""Load the from-scratch run config shipped with this directory."""

from __future__ import annotations

import json
from pathlib import Path

CONFIG_PATH = Path(__file__).resolve().parent / "run_config.json"


def load_run_config(path: Path | None = None) -> dict:
    config_path = path or CONFIG_PATH
    data = json.loads(config_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"run config must be an object: {config_path}")
    tokenizer_id = str(data.get("tokenizer_id") or "").strip()
    if not tokenizer_id:
        raise ValueError(f"run config missing tokenizer_id: {config_path}")
    return data
