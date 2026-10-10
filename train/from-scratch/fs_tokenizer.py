"""Load the 7B QLoRA tokenizer from a local HF snapshot.

Trainers do not download weights. The snapshot is the hub cache documented in
docs/HUB_ARTIFACTS.md (`models--Qwen--Qwen2.5-Coder-7B-Instruct`).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from fs_config import load_run_config


class TokenizerError(RuntimeError):
    pass


class HfTokenizer:
    def __init__(self, tokenizer_id: str, eos_token: str, eos_token_id: int, unk_token_id: int | None, inner) -> None:
        self.tokenizer_id = tokenizer_id
        self.eos_token = eos_token
        self.eos_token_id = eos_token_id
        self.unk_token_id = unk_token_id
        self.vocab_size = int(inner.get_vocab_size(with_added_tokens=True))
        self._inner = inner

    def encode(self, text: str) -> list[int]:
        encoded = self._inner.encode(text)
        ids = getattr(encoded, "ids", encoded)
        return [int(token_id) for token_id in ids]


def _hub_roots() -> list[Path]:
    roots: list[Path] = []
    hf_home = os.environ.get("HF_HOME", "").strip()
    if hf_home:
        roots.append(Path(hf_home))
    roots.append(Path.home() / ".cache" / "huggingface")
    roots.append(Path("/mnt/cluster-ssd/models/huggingface"))
    roots.append(Path("/mnt/cluster/models/huggingface"))
    return roots


def _repo_dirname(tokenizer_id: str) -> str:
    return "models--" + tokenizer_id.replace("/", "--")


def find_tokenizer_json(tokenizer_id: str, explicit: Path | None = None) -> Path | None:
    if explicit is not None:
        candidate = explicit
        if candidate.is_dir():
            candidate = candidate / "tokenizer.json"
        return candidate if candidate.is_file() else None
    repo_dir = _repo_dirname(tokenizer_id)
    for root in _hub_roots():
        snapshots = root / "hub" / repo_dir / "snapshots"
        if not snapshots.is_dir():
            continue
        matches = sorted(snapshots.glob("*/tokenizer.json"))
        if matches:
            return matches[-1]
    return None


def load_hf_tokenizer(tokenizer_id: str, explicit_json: Path | None = None, expected_eos: str | None = None) -> HfTokenizer:
    try:
        from tokenizers import Tokenizer
    except ImportError as exc:
        raise TokenizerError(
            "The tokenizers package is not installed. "
            "Install train/from-scratch/requirements.txt (Hugging Face tokenizers). "
            "Do not pip install a CUDA wheel for this step."
        ) from exc

    tokenizer_json = find_tokenizer_json(tokenizer_id, explicit_json)
    if tokenizer_json is None:
        roots = ", ".join(str(path) for path in _hub_roots())
        raise TokenizerError(
            f"tokenizer.json for {tokenizer_id} was not found under {roots}. "
            "Seed it on hub with scripts/hub_hub_models.sh pull hf "
            f"{tokenizer_id} and promote the 7B cache. Do not download on a trainer."
        )
    inner = Tokenizer.from_file(str(tokenizer_json))
    config_path = tokenizer_json.with_name("tokenizer_config.json")
    eos_token = expected_eos or ""
    unk_token = None
    if config_path.is_file():
        config = json.loads(config_path.read_text(encoding="utf-8"))
        eos_token = str(config.get("eos_token") or eos_token)
        unk_token = config.get("unk_token")
    if not eos_token:
        loaded = load_run_config()
        eos_token = str(loaded["tokenizer_eos_token"])
    eos_id = inner.token_to_id(eos_token)
    if eos_id is None:
        raise TokenizerError(f"{tokenizer_json} has no id for eos token {eos_token!r}")
    unk_id = inner.token_to_id(unk_token) if isinstance(unk_token, str) and unk_token else None
    return HfTokenizer(tokenizer_id, eos_token, int(eos_id), None if unk_id is None else int(unk_id), inner)
