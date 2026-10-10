#!/usr/bin/env python3
"""Build OpenAI-messages JSONL for 7B cluster FAQ chat SFT.

Axolotl mix: completion corpus + type chat_template (OpenAI messages).
  https://docs.axolotl.ai/docs/dataset-formats/
OpenAI messages rows:
  https://docs.axolotl.ai/docs/dataset-formats/conversation.html
Axolotl dataset weight only subsamples (0, 1]; it cannot upsample. This
script repeats unique turns at JSONL write time (--repeats, default 50).
  https://github.com/axolotl-ai-cloud/axolotl/blob/main/src/axolotl/utils/schemas/datasets.py
Start stages the file to the hub; qlora_continue.py --extra-jsonl hashes it
into dataset_prepared_path (cluster policy, not an Axolotl flag).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

# Unique user/assistant pairs. --repeats duplicates rows here (cluster JSONL
# preprocess) because Axolotl weight cannot upsample the mix.
UNIQUE_TURNS: list[tuple[str, str]] = [
    (
        "Can I attach this 7B LoRA to the 27B inference coordinator?",
        "No. The 7B LoRA is Qwen2.5-Coder-7B and serves only on standalone "
        "llama-server on gaming-c port 8470. Do not pass --lora to the inference "
        "coordinator on hub:31360. Base weights and vocab differ from "
        "Qwen3.8-27B. Do not convert this 7B GGUF into an RPC shard.",
    ),
    (
        "Can I apply pool-7b-qlora-v2.gguf onto frontier-code or qwen3.6-27b?",
        "No. Do not put the 7B LoRA on the 27B coordinator or into "
        "inference_SHARDS.env. Serve it with Start-Alfa7bServe on gaming-c:8470 only.",
    ),
    (
        "Can I run 7B QLoRA training and this 7B llama-server on Colin (gaming-c) at the same time?",
        "No. Train and 7B-serve are mutually exclusive on the gaming-c GPU. "
        "Stop trainer (clear alfa-train.lock) before Start-Alfa7bServe. "
        "Stop 7B serve before Start 7B QLoRA.",
    ),
    # SFT paraphrases of live-gate fact 1 (attach 7B LoRA to inference) -- gate unchanged.
    (
        "Should I load pool-7b-qlora-v2.gguf as --lora on the inference coordinator?",
        "No. The 7B LoRA is Qwen2.5-Coder-7B and serves only on standalone "
        "llama-server on gaming-c port 8470. Do not pass --lora to the inference "
        "coordinator on hub:31360. Base weights and vocab differ from "
        "Qwen3.8-27B. Do not convert this 7B GGUF into an RPC shard.",
    ),
    (
        "Can I merge this 7B QLoRA adapter into the 27B RPC pool?",
        "No. The 7B LoRA is Qwen2.5-Coder-7B and serves only on standalone "
        "llama-server on gaming-c port 8470. Do not pass --lora to the inference "
        "coordinator on hub:31360. Base weights and vocab differ from "
        "Qwen3.8-27B. Do not convert this 7B GGUF into an RPC shard.",
    ),
    # SFT paraphrases of live-gate fact 2 (frontier-code / qwen3.6-27b).
    (
        "Can frontier-code use this 7B LoRA from the hub?",
        "No. Do not put the 7B LoRA on the 27B coordinator or into "
        "inference_SHARDS.env. Serve it with Start-Alfa7bServe on gaming-c:8470 only.",
    ),
    (
        "Is it OK to point qwen3.6-27b at pool-7b-qlora-v2.gguf?",
        "No. Do not put the 7B LoRA on the 27B coordinator or into "
        "inference_SHARDS.env. Serve it with Start-Alfa7bServe on gaming-c:8470 only.",
    ),
    # SFT paraphrases of live-gate fact 3 (train vs 7B-serve mutex on gaming-c).
    (
        "Can I Start-Alfa7bServe while the 7B trainer is running on gaming-c?",
        "No. Train and 7B-serve are mutually exclusive on the gaming-c GPU. "
        "Stop trainer (clear alfa-train.lock) before Start-Alfa7bServe. "
        "Stop 7B serve before Start 7B QLoRA.",
    ),
    (
        "Is it safe to run 7B QLoRA and llama-server :8470 together on gaming_worker_c?",
        "No. Train and 7B-serve are mutually exclusive on the gaming-c GPU. "
        "Stop trainer (clear alfa-train.lock) before Start-Alfa7bServe. "
        "Stop 7B serve before Start 7B QLoRA.",
    ),
    (
        "Can alfa-train run on gaming-c while the 27B coordinator stays up?",
        "Yes, core inference on inference/hub may stay up during 7B QLoRA. "
        "No, you cannot also run 7B llama-server on that same gaming-c GPU while training.",
    ),
    (
        "Which hosts are the trainer island, and which host serves this 7B on port 8470?",
        "Trainer island is gaming-c, gaming-b, and optional gaming-a. inference is not a train rank; "
        "it stays on inference core. 7B llama-server is only gaming-c:8470. Do not serve "
        "7B on gaming-b:8470 or on hub.",
    ),
    (
        "Is inference part of the trainer island?",
        "No. inference stays on 27B inference core. Trainer island hosts are gaming-c, gaming-b, "
        "and optional gaming-a only.",
    ),
    (
        "Where is WorkflowRunner planning implemented?",
        "In src/runtime/workflow.py. The planner calls plan_implement_review_fix.",
    ),
    (
        "What line must check-work end with?",
        "End with exactly VERDICT: PASS or VERDICT: FAIL on its own line.",
    ),
    (
        "Default ALFA_AI_AGENT_MUTATE_ENABLED value?",
        "Default ALFA_AI_AGENT_MUTATE_ENABLED is 0 (false / off). "
        "Mutate stays disabled until the operator sets ALFA_AI_AGENT_MUTATE_ENABLED=1.",
    ),
    (
        "Host IPs for trainer island?",
        "Trainer island is gaming-c, gaming-b, and optional gaming-a. Not inference, not orchestrator, not hub.",
    ),
]

# Live-gate facts 1 and 3 (inference LoRA attach; train vs 7B-serve mutex) plus their
# paraphrase rows. Fact 2 (frontier-code) already passes live FAQ; do not upsample it.
GATE_FACT13_INDICES: tuple[int, ...] = (0, 2, 3, 4, 7, 8)


def _row_for_turn(user: str, assistant: str) -> dict[str, object]:
    return {
        "messages": [
            {"role": "user", "content": user},
            {"role": "assistant", "content": assistant},
        ]
    }


def build_rows(repeats: int, extra_repeats_gate_fact13: int = 0) -> list[dict[str, object]]:
    if repeats < 1:
        raise ValueError("repeats must be >= 1")
    if extra_repeats_gate_fact13 < 0:
        raise ValueError("extra_repeats_gate_fact13 must be >= 0")
    rows: list[dict[str, object]] = []
    for _ in range(repeats):
        for user, assistant in UNIQUE_TURNS:
            rows.append(_row_for_turn(user, assistant))
    for _ in range(extra_repeats_gate_fact13):
        for idx in GATE_FACT13_INDICES:
            user, assistant = UNIQUE_TURNS[idx]
            rows.append(_row_for_turn(user, assistant))
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Write 7B cluster FAQ chat JSONL.")
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="Output JSONL path (OpenAI messages rows).",
    )
    parser.add_argument(
        "--repeats",
        type=int,
        default=50,
        help=(
            "Cluster JSONL preprocess: repeat each unique turn N times "
            "(Axolotl weight subsamples only)."
        ),
    )
    parser.add_argument(
        "--extra-repeats-gate-fact13",
        type=int,
        default=50,
        help=(
            "Additional passes over live-gate facts 1 and 3 rows only "
            "(indices 0,2,3,4,7,8). Upsamples No-answers for inference attach "
            "and train/serve mutex without bloating fact 2."
        ),
    )
    args = parser.parse_args(argv)
    rows = build_rows(args.repeats, args.extra_repeats_gate_fact13)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="\n") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=True) + "\n")
    extra = len(GATE_FACT13_INDICES) * args.extra_repeats_gate_fact13
    base = len(UNIQUE_TURNS) * args.repeats
    print(
        "OK unique={0} repeats={1} extra_gate_fact13={2} rows={3} (base={4}+extra={5}) out={6}".format(
            len(UNIQUE_TURNS),
            args.repeats,
            args.extra_repeats_gate_fact13,
            len(rows),
            base,
            extra,
            args.out,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
