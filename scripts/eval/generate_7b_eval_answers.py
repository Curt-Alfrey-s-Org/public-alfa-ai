#!/usr/bin/env python3
"""Generate answers JSONL for train_checkpoint_gate.py by calling 7B endpoints.

Calls OpenAI-compatible /v1/chat/completions
(https://platform.openai.com/docs/api-reference/chat/create).

On gaming-c (12 GB) only one llama-server runs on :8470 at a time
(https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md).
Eval is sequential: --only base, stop serve, switch base vs --lora, --only checkpoint.
Do not run two 7B servers on one GPU.

--only both is for two already-live OpenAI base URLs (e.g. base on one host, checkpoint
on another). It does not start serve or imply two concurrent 7B containers on gaming-c:8470.
If both URLs share the same origin (e.g. both http://orchestrator/v1), the script
warns: use --only base then --only checkpoint with stop between instead.

Usage (gaming-c sequential):
  python scripts/eval/generate_7b_eval_answers.py --only base \\
    --base-url http://orchestrator/v1 \\
    --out-base C:/Users/operator\\alfa-ai-cache\\eval\\7b-v2-base-answers.jsonl
  python scripts/eval/generate_7b_eval_answers.py --only checkpoint \\
    --checkpoint-url http://orchestrator/v1 \\
    --out-checkpoint C:/Users/operator\\alfa-ai-cache\\eval\\7b-v2-ckpt-answers.jsonl

Then:
  python scripts/eval/train_checkpoint_gate.py \\
    --answers-base /tmp/7b-base-answers.jsonl \\
    --answers-checkpoint /tmp/7b-ckpt-answers.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from scripts.eval.smoke_runner import DEFAULT_GOLD, load_jsonl  # noqa: E402


def _normalize_v1(base: str) -> str:
    b = base.rstrip("/")
    if b.endswith("/v1"):
        return b
    return b + "/v1"


def _url_origin(url: str) -> str:
    """scheme://host:port for same-origin checks (path suffix like /v1 ignored)."""
    parsed = urlparse(url.strip())
    if not parsed.scheme or not parsed.netloc:
        return url.strip().rstrip("/").lower()
    return f"{parsed.scheme}://{parsed.netloc}".lower()


def chat_completion(
    *,
    api_base: str,
    model: str,
    prompt: str,
    api_key: str = "change-me",
    timeout: float = 120.0,
    max_tokens: int = 512,
) -> str:
    url = _normalize_v1(api_base) + "/chat/completions"
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.2,
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"HTTP {exc.code} from {url}: {detail}") from exc
    choices = payload.get("choices") or []
    if not choices:
        return ""
    message = choices[0].get("message") or {}
    return str(message.get("content") or "")


def generate_answers(
    *,
    gold_path: Path,
    api_base: str,
    model: str,
    api_key: str,
    timeout: float,
) -> list[dict]:
    gold = load_jsonl(gold_path)
    rows: list[dict] = []
    for item in gold:
        item_id = str(item.get("id") or "")
        goal = str(item.get("goal") or item.get("prompt") or "")
        if not item_id or not goal:
            continue
        answer = chat_completion(
            api_base=api_base,
            model=model,
            prompt=goal,
            api_key=api_key,
            timeout=timeout,
        )
        rows.append({"id": item_id, "answer": answer})
    return rows


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=True) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate 7B eval answers JSONL")
    parser.add_argument("--gold", type=Path, default=DEFAULT_GOLD)
    parser.add_argument(
        "--only",
        choices=("both", "base", "checkpoint"),
        required=True,
        help=(
            "Required. On gaming-c use base or checkpoint (one llama-server on :8470; stop "
            "between passes). both calls two already-live OpenAI base URLs in one run "
            "(e.g. different hosts) -- not two concurrent 7B servers on one GPU."
        ),
    )
    parser.add_argument("--base-url", help="OpenAI base for base 7B (no LoRA)")
    parser.add_argument("--checkpoint-url", help="OpenAI base for adapter 7B")
    parser.add_argument("--base-model", default="qwen2.5-coder-7b")
    parser.add_argument("--checkpoint-model", default="qwen2.5-coder-7b")
    parser.add_argument("--out-base", type=Path)
    parser.add_argument("--out-checkpoint", type=Path)
    parser.add_argument("--api-key", default="change-me")
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args(argv)

    want_base = args.only in ("both", "base")
    want_ckpt = args.only in ("both", "checkpoint")
    if want_base and (not args.base_url or not args.out_base):
        print("--only base|both requires --base-url and --out-base", file=sys.stderr)
        return 2
    if want_ckpt and (not args.checkpoint_url or not args.out_checkpoint):
        print("--only checkpoint|both requires --checkpoint-url and --out-checkpoint", file=sys.stderr)
        return 2

    if args.only == "both" and args.base_url and args.checkpoint_url:
        if _url_origin(args.base_url) == _url_origin(args.checkpoint_url):
            print(
                "warning: --only both with the same OpenAI base URL origin "
                f"({_url_origin(args.base_url)}). On gaming-c only one llama-server runs on "
                ":8470 at a time. Use --only base, stop serve, switch mode (base vs "
                "--lora), then --only checkpoint.",
                file=sys.stderr,
            )

    print(f"gold={args.gold} items={len(load_jsonl(args.gold))} only={args.only}", file=sys.stderr)
    if want_base:
        print(f"base -> {args.base_url} model={args.base_model}", file=sys.stderr)
        base_rows = generate_answers(
            gold_path=args.gold,
            api_base=args.base_url,
            model=args.base_model,
            api_key=args.api_key,
            timeout=args.timeout,
        )
        write_jsonl(args.out_base, base_rows)
        print(f"wrote {args.out_base} ({len(base_rows)} rows)", file=sys.stderr)

    if want_ckpt:
        print(f"checkpoint -> {args.checkpoint_url} model={args.checkpoint_model}", file=sys.stderr)
        ckpt_rows = generate_answers(
            gold_path=args.gold,
            api_base=args.checkpoint_url,
            model=args.checkpoint_model,
            api_key=args.api_key,
            timeout=args.timeout,
        )
        write_jsonl(args.out_checkpoint, ckpt_rows)
        print(f"wrote {args.out_checkpoint} ({len(ckpt_rows)} rows)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
