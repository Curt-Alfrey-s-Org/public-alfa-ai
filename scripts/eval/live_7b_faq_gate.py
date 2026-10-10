#!/usr/bin/env python3
"""Live Yes/No polarity gate for 7B FAQ (standalone llama-server).

Asks the first three UNIQUE_TURNS user prompts
(scripts/build_7b_cluster_faq_chat.py) via OpenAI-compatible
POST /v1/chat/completions
(https://platform.openai.com/docs/api-reference/chat/create).

Polarity is the first Yes/No token (case-insensitive). Wrong polarity
fails even when the 10-item keyword smoke log printed promote_allowed.
This is not a LiteLLM or llama.cpp SLO. Do not set LLAMACPP_7B_URL from
this script.

PS 5.1 curl.exe -d JSON quote-stripping is why this is Python urllib,
not an operator curl paste
(https://learn.microsoft.com/en-us/windows/curl/).

Usage:
  python scripts/eval/live_7b_faq_gate.py
  python scripts/eval/live_7b_faq_gate.py --self-check
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from scripts.build_7b_cluster_faq_chat import UNIQUE_TURNS  # noqa: E402
from scripts.eval.generate_7b_eval_answers import chat_completion  # noqa: E402

LIVE_GATE_TURNS = UNIQUE_TURNS[:3]


_YES_NO_AT_START = re.compile(r"(?is)^[\s*_`>#~\-]*(yes|no)\b")


def first_yes_no(text: str) -> str | None:
    """Return 'yes' or 'no' from the start of the reply, else None."""
    raw = (text or "").strip()
    if not raw:
        return None
    match = _YES_NO_AT_START.match(raw)
    if match is None:
        return None
    return match.group(1).lower()


def expected_yes_no(assistant: str) -> str:
    got = first_yes_no(assistant)
    if got is None:
        raise ValueError("UNIQUE_TURNS assistant must start with Yes or No")
    return got


def run_self_check() -> int:
    frozen = (
        "Can I attach this 7B LoRA to the 27B inference coordinator?",
        "Can I apply pool-7b-qlora-v2.gguf onto frontier-code or qwen3.6-27b?",
        "Can I run 7B QLoRA training and this 7B llama-server on Colin (gaming-c) at the same time?",
    )
    users = tuple(u for u, _ in LIVE_GATE_TURNS)
    if users != frozen:
        print("FAIL: frozen live-gate prompts drifted", file=sys.stderr)
        return 1
    for user, assistant in LIVE_GATE_TURNS:
        if expected_yes_no(assistant) != "no":
            print(f"FAIL: expected No for {user!r}", file=sys.stderr)
            return 1
    if first_yes_no("No. The 7B LoRA is Qwen2.5-Coder-7B") != "no":
        print("FAIL: polarity helper missed leading No.", file=sys.stderr)
        return 1
    if first_yes_no("**Yes** you can") != "yes":
        print("FAIL: polarity helper missed markdown Yes", file=sys.stderr)
        return 1
    if first_yes_no("Maybe later") is not None:
        print("FAIL: polarity helper should ignore non Yes/No", file=sys.stderr)
        return 1
    print("self-check OK: 3 frozen prompts, polarity helper")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Live 7B FAQ Yes/No polarity gate")
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument(
        "--base-url",
        default="http://orchestrator/v1",
        help="OpenAI-compatible base (llama-server with adapter loaded)",
    )
    parser.add_argument("--model", default="qwen2.5-coder-7b")
    parser.add_argument("--api-key", default="change-me")
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--max-tokens", type=int, default=128)
    args = parser.parse_args(argv)

    if args.self_check:
        return run_self_check()

    failed = 0
    for idx, (user, assistant) in enumerate(LIVE_GATE_TURNS, start=1):
        want = expected_yes_no(assistant)
        answer = chat_completion(
            api_base=args.base_url,
            model=args.model,
            prompt=user,
            api_key=args.api_key,
            timeout=args.timeout,
            max_tokens=args.max_tokens,
        )
        got = first_yes_no(answer)
        preview = " ".join((answer or "").split())[:240]
        ok = got == want
        mark = "PASS" if ok else "FAIL"
        print(f"[{mark}] FAQ{idx} want={want} got={got or 'none'}")
        print(f"  Q: {user}")
        print(f"  A: {preview}")
        if not ok:
            failed += 1

    if failed:
        print(
            f"FAIL: {failed}/{len(LIVE_GATE_TURNS)} live FAQ polarity mismatches. "
            "Stop 7B serve, continue-train FAQ, reconvert, retest the same three "
            "prompts. Do not set LLAMACPP_7B_URL.",
            file=sys.stderr,
        )
        return 1
    print(
        "OK: live FAQ polarity passed. Do not set LLAMACPP_7B_URL unless the "
        "operator asks after this gate."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
