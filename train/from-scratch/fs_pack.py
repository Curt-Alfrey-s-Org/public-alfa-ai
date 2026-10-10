"""Pack one repo's files into fixed windows with an EOS token after each file."""

from __future__ import annotations

import struct
from pathlib import Path


def encode_documents(texts: list[str], encode, eos_token_id: int) -> list[int]:
    """Concatenate token ids. EOS is appended to every file, so it sits between files."""
    stream: list[int] = []
    for text in texts:
        stream.extend(encode(text))
        stream.append(eos_token_id)
    return stream


def windows_from_stream(stream: list[int], seq_len: int) -> tuple[list[list[int]], int]:
    """Split a token stream into full seq_len windows. The tail is dropped."""
    if seq_len < 1:
        raise ValueError("seq_len must be positive")
    count = len(stream) // seq_len
    windows = [stream[index * seq_len : (index + 1) * seq_len] for index in range(count)]
    remainder = len(stream) - count * seq_len
    return windows, remainder


def write_u32_shard(path: Path, windows: list[list[int]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        for window in windows:
            handle.write(struct.pack(f"<{len(window)}I", *window))


def read_u32_shard(path: Path, seq_len: int) -> list[list[int]]:
    raw = path.read_bytes()
    if len(raw) % 4 != 0:
        raise ValueError(f"shard length is not a multiple of 4: {path}")
    count = len(raw) // 4
    if seq_len < 1 or count % seq_len != 0:
        raise ValueError(f"shard token count {count} is not a multiple of seq_len {seq_len}")
    values = list(struct.unpack(f"<{count}I", raw))
    return [values[index : index + seq_len] for index in range(0, count, seq_len)]


def unk_rate(token_ids: list[int], unk_token_id: int | None) -> float:
    if unk_token_id is None or not token_ids:
        return 0.0
    hits = sum(1 for token_id in token_ids if token_id == unk_token_id)
    return hits / len(token_ids)
