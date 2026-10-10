#!/usr/bin/env python3
"""Offline eval smoke runner (learning-loop L0 / Milestone 5).

Does not call LLMs. Scores gold prompts against fixed reference answers
or simple must_include_any checks on a provided answers JSONL. Used by
train_checkpoint_gate.py for cluster smoke logs (not LiteLLM / not an SLO).

Usage:
  python scripts/eval/smoke_runner.py
  python scripts/eval/smoke_runner.py --answers path/to/answers.jsonl
  python scripts/eval/smoke_runner.py --self-check
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

DEFAULT_GOLD = _REPO / "eval" / "gold" / "smoke.jsonl"

# Built-in reference answers for --self-check (no model required)
_SELF_CHECK_ANSWERS: dict[str, str] = {
    "smoke-01": "See deploy/litellm_config.yaml for LiteLLM routing.",
    "smoke-02": "ALFA_AI_AGENT_MODEL defaults to frontier-code.",
    "smoke-03": "src/runtime/workflow.py plan_implement_review_fix",
    "smoke-04": "End with VERDICT: PASS or VERDICT: FAIL",
    "smoke-05": "LEARNING_LOOP_JUDGE_SLEEP.md is the learning loop SSoT plan",
    "smoke-06": "ALFA_AI_AGENT_MUTATE_ENABLED defaults to 0 (off)",
    "smoke-07": "errors.jsonl under ALFA_AI_DATA",
    "smoke-08": "Trainer island is gaming-c gaming-b gaming-a",
    "smoke-09": "pytest / lint / check-work are primary gates",
    "smoke-10": "skill audit-repo",
}


def load_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    if not path.is_file():
        return rows
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    return rows


def score_item(item: dict, answer: str) -> tuple[bool, str]:
    needles = item.get("must_include_any") or []
    if not needles:
        return True, "no criteria"
    text = (answer or "").lower()
    for needle in needles:
        if str(needle).lower() in text:
            return True, f"matched:{needle}"
    return False, "no must_include_any match"


def run(
    *,
    gold_path: Path,
    answers: dict[str, str],
) -> dict:
    gold = load_jsonl(gold_path)
    results = []
    passed = 0
    for item in gold:
        item_id = str(item.get("id") or "")
        answer = answers.get(item_id, "")
        ok, reason = score_item(item, answer)
        if ok:
            passed += 1
        results.append(
            {
                "id": item_id,
                "suite": item.get("suite"),
                "pass": ok,
                "reason": reason,
                "goal": item.get("goal"),
            }
        )
    total = len(gold)
    return {
        "ok": total > 0 and passed == total,
        "passed": passed,
        "total": total,
        "pass_rate": (passed / total) if total else 0.0,
        "results": results,
        "gold": str(gold_path),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="ALFa eval smoke runner (offline)")
    parser.add_argument("--gold", type=Path, default=DEFAULT_GOLD)
    parser.add_argument(
        "--answers",
        type=Path,
        default=None,
        help="JSONL with {id, answer} rows",
    )
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="Score built-in reference answers (CI smoke)",
    )
    parser.add_argument("--json", action="store_true", help="Print full JSON report")
    args = parser.parse_args(argv)

    answers: dict[str, str] = {}
    if args.self_check:
        answers = dict(_SELF_CHECK_ANSWERS)
    if args.answers and args.answers.is_file():
        for row in load_jsonl(args.answers):
            answers[str(row.get("id") or "")] = str(row.get("answer") or row.get("text") or "")

    if not answers:
        print("No answers provided. Use --self-check or --answers FILE.", file=sys.stderr)
        return 2

    report = run(gold_path=args.gold, answers=answers)
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=True))
    else:
        print(f"eval smoke: {report['passed']}/{report['total']} ({report['pass_rate']:.0%})")
        for row in report["results"]:
            mark = "PASS" if row["pass"] else "FAIL"
            print(f"  [{mark}] {row['id']}: {row['reason']}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
