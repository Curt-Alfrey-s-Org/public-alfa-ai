#!/usr/bin/env python3
"""Cluster smoke log for L3 train checkpoints (keyword needles vs gold).

Org-defined regression log
([NIST AI RMF MEASURE 2.3](https://airc.nist.gov/airmf-resources/playbook/measure/)),
not an official eval or deployment SLO. Per Google SRE practice, avoid targeting
100% ([SLOs](https://sre.google/sre-book/service-level-objectives/)); 10 needles
in eval/gold/smoke.jsonl are a small held-out check, not proof of production
readiness. Do not report lm-eval `--limit` scores as deployment gates (subset
testing only:
https://github.com/EleutherAI/lm-evaluation-harness/blob/main/docs/interface.md).

Does not call production frontier-code, LiteLLM, or llama.cpp. Compares answers
JSONL from base vs checkpoint on eval/gold/smoke.jsonl using must_include_any
keyword matching (extend with your own gold set).

promote_allowed (compat field): script output when checkpoint rate >=
PASS_THRESHOLD (0.70) and not worse than base. It is NOT enforced by LiteLLM
or llama.cpp. Set LLAMACPP_7B_URL / LiteLLM alfa-coder-draft only after live
FAQ chat passes and the operator explicitly asks (docs/operations/
ALFA_7B_SERVE_ALONGSIDE_27B.md). Never point frontier-code (27B pool) at 7B
adapter weights.

Usage:
  python scripts/eval/train_checkpoint_gate.py --answers-base base.jsonl --answers-checkpoint ckpt.jsonl
  python scripts/eval/train_checkpoint_gate.py --self-check
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from scripts.eval.smoke_runner import DEFAULT_GOLD, load_jsonl, score_item  # noqa: E402

PASS_THRESHOLD = 0.70

_PROMOTE_NOTE = (
    "promote_allowed is cluster smoke-script output (keyword needles vs "
    "eval/gold/smoke.jsonl); it is not a LiteLLM or llama.cpp SLO. Set "
    "LLAMACPP_7B_URL / LiteLLM alfa-coder-draft only after live FAQ chat on "
    ":8470 passes and the operator explicitly asks "
    "(docs/operations/ALFA_7B_SERVE_ALONGSIDE_27B.md). Never point "
    "frontier-code (27B pool) at 7B adapter weights."
)


def _print_smoke_log(label: str, scored: dict) -> None:
    print(
        f"{label} smoke: passed={scored['passed']} total={scored['total']} "
        f"rate={scored['rate']}"
    )
    for row in scored.get("results", []):
        mark = "PASS" if row["ok"] else "FAIL"
        print(f"  [{mark}] {row['id']}: {row['reason']}")


def answers_from_jsonl(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for row in load_jsonl(path):
        item_id = str(row.get("id") or row.get("prompt_id") or "")
        answer = str(row.get("answer") or row.get("response") or row.get("content") or "")
        if item_id:
            out[item_id] = answer
    return out


def score_answers(gold_path: Path, answers: dict[str, str]) -> dict:
    gold = load_jsonl(gold_path)
    results = []
    passed = 0
    for item in gold:
        item_id = str(item.get("id") or "")
        answer = answers.get(item_id, "")
        ok, reason = score_item(item, answer)
        if ok:
            passed += 1
        results.append({"id": item_id, "ok": ok, "reason": reason})
    total = len(gold) or 1
    rate = passed / total
    return {
        "passed": passed,
        "total": len(gold),
        "rate": round(rate, 4),
        "ok": rate >= PASS_THRESHOLD,
        "threshold": PASS_THRESHOLD,
        "results": results,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Cluster smoke log for train checkpoints (not LiteLLM)"
    )
    parser.add_argument("--gold", type=Path, default=DEFAULT_GOLD)
    parser.add_argument("--answers-base", type=Path)
    parser.add_argument("--answers-checkpoint", type=Path)
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    if args.self_check:
        from scripts.eval.smoke_runner import _SELF_CHECK_ANSWERS  # noqa: PLC0415

        base = score_answers(args.gold, _SELF_CHECK_ANSWERS)
        # Simulate checkpoint at 80% by dropping two answers
        partial = dict(_SELF_CHECK_ANSWERS)
        for key in list(partial.keys())[:5]:
            partial.pop(key, None)
        ckpt = score_answers(args.gold, partial)
        report = {
            "ok": base["ok"] and not ckpt["ok"],
            "base": base,
            "checkpoint": ckpt,
            "note": "self-check expects base pass and partial fail",
        }
        if args.json:
            print(json.dumps(report, indent=2, ensure_ascii=True))
        else:
            _print_smoke_log("base", base)
            _print_smoke_log("checkpoint", ckpt)
            print(f"gate_ok={report['ok']}")
        return 0 if report["ok"] else 1

    if not args.answers_base or not args.answers_checkpoint:
        print("Provide --answers-base and --answers-checkpoint", file=sys.stderr)
        return 2

    base = score_answers(args.gold, answers_from_jsonl(args.answers_base))
    ckpt = score_answers(args.gold, answers_from_jsonl(args.answers_checkpoint))
    delta = ckpt["rate"] - base["rate"]
    report = {
        "ok": ckpt["ok"] and ckpt["rate"] >= base["rate"],
        "base": base,
        "checkpoint": ckpt,
        "delta_rate": round(delta, 4),
        "promote_allowed": ckpt["ok"] and delta >= 0,
        "note": _PROMOTE_NOTE,
    }
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=True))
    else:
        _print_smoke_log("base", base)
        _print_smoke_log("checkpoint", ckpt)
        print(
            f"delta_rate={report['delta_rate']} "
            f"threshold={PASS_THRESHOLD} promote_allowed={report['promote_allowed']}"
        )
        print(report["note"])
    return 0 if report["promote_allowed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
