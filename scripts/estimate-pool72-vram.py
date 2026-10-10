#!/usr/bin/env python3
"""Estimate Pool72 (Qwen2.5-72B dense) weight + KV VRAM per tensor-split shard.

Architecture (official HF config.json for Qwen/Qwen2.5-72B-Instruct):
  num_hidden_layers=80, num_attention_heads=64, num_key_value_heads=8,
  hidden_size=8192 => head_dim=128, max_position_embeddings=32768
  Long context: YaRN up to 131072 (factor = CTX/32768).

KV formula (llama.cpp / GQA, approximate; q4_0 cache ~0.5 B/elem):
  KV_bytes ~= 2 * n_layer * n_kv_heads * head_dim * ctx_total * bytes_per_elem

Weights: Q5_K_M GGUF ~51.7 GiB (disk); treated as ~51.7 GiB VRAM for weights.

Per-GPU share (RPC --tensor-split proportions, multi-gpu.md):
  share_i = (weights + KV) * (ts_i / sum(ts))

Official refs:
  https://huggingface.co/Qwen/Qwen2.5-72B-Instruct
  https://github.com/ggml-org/llama.cpp/blob/master/docs/multi-gpu.md
  https://github.com/ggml-org/llama.cpp/discussions/10068

Usage:
  python3 scripts/estimate-pool72-vram.py
  python3 scripts/estimate-pool72-vram.py --ctx 65536 --shards-file deploy/llamacpp-rpc/pool72-shards.core.env
"""
from __future__ import annotations

import argparse
import math
from pathlib import Path

# Official Qwen2.5-72B-Instruct
N_LAYER = 80
N_KV_HEADS = 8
HEAD_DIM = 128  # hidden_size 8192 / num_attention_heads 64
WEIGHTS_GIB = 51.7
BYTES_Q4 = 0.5
OVERHEAD_GIB = 1.0  # CUDA context / compute buffers (conservative flat per GPU)


def kv_gib(ctx: int, bytes_per: float = BYTES_Q4) -> float:
    return (2 * N_LAYER * N_KV_HEADS * HEAD_DIM * ctx * bytes_per) / (1024**3)


def parse_shards(path: Path) -> list[tuple[str, int, float]]:
    rows: list[tuple[str, int, float]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        host, port_s, vram_s = parts[0], parts[1], parts[2]
        # HOST PORT VRAM [LABEL] [PCT]  or  HOST PORT VRAM [PCT]
        pct = None
        if len(parts) >= 5 and parts[4].replace(".", "", 1).isdigit():
            pct = float(parts[4])
        elif len(parts) == 4 and parts[3].replace(".", "", 1).isdigit():
            pct = float(parts[3])
        vram = float(vram_s)
        ts = vram * (pct / 100.0) if pct is not None else vram
        rows.append((f"{host}:{port_s}", int(port_s), ts))
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ctx", type=int, default=86016)
    ap.add_argument(
        "--core",
        type=Path,
        default=Path("deploy/llamacpp-rpc/pool72-shards.core.env"),
    )
    ap.add_argument(
        "--gaming",
        type=Path,
        default=Path("deploy/llamacpp-rpc/pool72-shards.gaming.env"),
    )
    ap.add_argument("--full-mesh", action="store_true", default=True)
    ap.add_argument("--core-only", action="store_true")
    args = ap.parse_args()
    if args.core_only:
        args.full_mesh = False

    rows = parse_shards(args.core)
    if args.full_mesh and args.gaming.is_file():
        # Approximate merge order: core before orchestrator, then gaming hosts except
        # secondary/pool-opt-in, then orchestrator block, then secondary/pool-opt-in -- for estimate only sum matters.
        rows.extend(parse_shards(args.gaming))

    ts_sum = sum(r[2] for r in rows)
    kv = kv_gib(args.ctx)
    total = WEIGHTS_GIB + kv
    print(f"Qwen2.5-72B Q5_K_M  weights={WEIGHTS_GIB:.1f} GiB  CTX={args.ctx}")
    print(f"KV(q4_0)={kv:.2f} GiB  weights+KV={total:.1f} GiB  TENSOR_SPLIT sum={ts_sum:.1f}")
    print(f"{'shard':<24} {'ts':>6} {'est+oh':>8}  note")
    for name, _port, ts in rows:
        est = total * (ts / ts_sum) + OVERHEAD_GIB
        print(f"{name:<24} {ts:6.1f} {est:8.2f}")
    print()
    print("Compare est+oh to physical VRAM (nvidia-smi). Leave >=1 GiB free on every GPU.")
    yarn = args.ctx / 32768.0
    print(f"YaRN ROPE_SCALE should be {yarn:g} when CTX>32768 (HF processing-long-texts).")


if __name__ == "__main__":
    main()
