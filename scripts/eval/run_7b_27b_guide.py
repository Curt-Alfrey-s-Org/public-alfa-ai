#!/usr/bin/env python3
"""Run the 7B draft + 27B judge guide loop and print a Grok audit excerpt.

Calls src.llm.draft_guide.run_draft_guide_loop (sibling module). Appends session
turns to JSONL per docs/operations/ALFA_7B_27B_WORK_JUDGE.md.

Usage:
  python scripts/eval/run_7b_27b_guide.py --task "Summarize inference health checks"
  python scripts/eval/run_7b_27b_guide.py --task "..." --max-rounds 2 --log logs/draft-judge/sessions.jsonl

Exit 0 on PASS (judge confirm); non-zero on FAIL (skipped/disabled, reject, exception).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

_REPO = Path(__file__).resolve().parents[2]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

DEFAULT_LOG = _REPO / "logs" / "draft-judge" / "sessions.jsonl"

def _redact_secrets(text: str) -> str:
    try:
        from src.llm.draft_guide import sanitize_secret_text
    except ImportError:
        return text
    return sanitize_secret_text(text, max_chars=None)


def _load_jsonl_tail(path: Path, max_lines: int) -> list[str]:
    if not path.is_file():
        return []
    lines = [ln for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]
    return lines[-max_lines:]


def _parse_jsonl_record(line: str) -> dict[str, Any] | None:
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        return None
    return row if isinstance(row, dict) else None


def _verdict_from_log(log_path: Path) -> str:
    """Best-effort last verdict or decision from session log."""
    if not log_path.is_file():
        return ""
    last_verdict = ""
    last_decision = ""
    for line in log_path.read_text(encoding="utf-8").splitlines():
        row = _parse_jsonl_record(line.strip())
        if not row:
            continue
        verdict = str(row.get("verdict") or "").strip().lower()
        if verdict in ("confirm", "revise", "reject"):
            last_verdict = verdict
        decision = str(row.get("decision") or "").strip().lower()
        if decision:
            last_decision = decision
    if last_decision in ("confirmed", "confirm"):
        return "confirm"
    if last_decision in ("rejected", "reject"):
        return "reject"
    return last_verdict


def _result_verdict(result: Any) -> str:
    if result is None:
        return ""
    if isinstance(result, dict):
        for key in ("final_verdict", "verdict"):
            val = str(result.get(key) or "").strip().lower()
            if val in ("confirm", "revise", "reject"):
                return val
        judge = result.get("judge")
        if isinstance(judge, dict):
            val = str(judge.get("verdict") or "").strip().lower()
            if val in ("confirm", "revise", "reject"):
                return val
        decision = str(result.get("decision") or "").strip().lower()
        if decision in ("confirmed", "confirm"):
            return "confirm"
        if decision in ("rejected", "reject", "max_rounds"):
            if decision == "max_rounds":
                return "revise"
            return "reject"
        return ""
    for attr in ("final_verdict", "verdict"):
        if hasattr(result, attr):
            val = str(getattr(result, attr) or "").strip().lower()
            if val in ("confirm", "revise", "reject"):
                return val
    if hasattr(result, "judge"):
        judge = getattr(result, "judge")
        if hasattr(judge, "verdict"):
            val = str(judge.verdict or "").strip().lower()
            if val in ("confirm", "revise", "reject"):
                return val
    if hasattr(result, "decision"):
        decision = str(getattr(result, "decision") or "").strip().lower()
        if decision in ("confirmed", "confirm"):
            return "confirm"
        if decision in ("rejected", "reject"):
            return "reject"
    return ""


def _judge_skipped_or_disabled(result: Any) -> tuple[bool, str]:
    if result is None:
        return False, ""
    if isinstance(result, dict):
        if result.get("error") or result.get("exception"):
            return True, str(result.get("error") or result.get("exception"))
        if result.get("judge_skipped") or result.get("skipped"):
            reason = str(result.get("skip_reason") or result.get("judge_skip_reason") or "judge skipped")
            return True, reason
        if result.get("judge_disabled") or result.get("enabled") is False:
            return True, str(result.get("skip_reason") or "judge disabled")
        judge = result.get("judge")
        if isinstance(judge, dict):
            if judge.get("skipped"):
                return True, str(judge.get("skip_reason") or "judge skipped")
            if judge.get("enabled") is False:
                return True, str(judge.get("skip_reason") or "judge disabled")
        return False, ""
    if getattr(result, "error", None):
        return True, str(result.error)
    if getattr(result, "judge_skipped", False) or getattr(result, "skipped", False):
        return True, str(getattr(result, "skip_reason", "") or "judge skipped")
    if getattr(result, "judge_disabled", False) or getattr(result, "enabled", True) is False:
        return True, str(getattr(result, "skip_reason", "") or "judge disabled")
    judge = getattr(result, "judge", None)
    if judge is not None:
        if getattr(judge, "skipped", False):
            return True, str(getattr(judge, "skip_reason", "") or "judge skipped")
        if getattr(judge, "enabled", True) is False:
            return True, str(getattr(judge, "skip_reason", "") or "judge disabled")
    return False, ""


def _evaluate_pass(result: Any, log_path: Path) -> tuple[bool, str]:
    skipped, skip_reason = _judge_skipped_or_disabled(result)
    if skipped:
        return False, skip_reason or "judge skipped or disabled"

    verdict = _result_verdict(result) or _verdict_from_log(log_path)
    if verdict == "confirm":
        return True, "verdict confirm"
    if verdict == "reject":
        return False, "verdict reject"
    if verdict == "revise":
        return False, "verdict revise (not confirmed)"
    return False, "no confirm verdict"


def _print_grok_audit_excerpt(log_path: Path, max_lines: int = 40) -> None:
    print("GROK_AUDIT_EXCERPT")
    tail = _load_jsonl_tail(log_path, max_lines)
    if not tail:
        print(f"(no lines in {log_path})")
        return
    for line in tail:
        print(_redact_secrets(line))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run 7B draft + 27B judge guide loop (Path B work-judge loop)"
    )
    parser.add_argument("--task", required=True, help="Operator task prompt for the loop")
    parser.add_argument(
        "--max-rounds",
        type=int,
        default=3,
        help="Max revise rounds (capped at 3)",
    )
    parser.add_argument(
        "--log",
        type=Path,
        default=DEFAULT_LOG,
        help="Session JSONL path (default logs/draft-judge/sessions.jsonl)",
    )
    args = parser.parse_args(argv)

    if args.max_rounds < 1:
        print("--max-rounds must be >= 1", file=sys.stderr)
        return 2
    if args.max_rounds > 3:
        print("--max-rounds capped at 3", file=sys.stderr)
        args.max_rounds = 3

    try:
        from src.llm.draft_guide import run_draft_guide_loop  # noqa: PLC0415
    except ImportError:
        print(
            "FAIL: src/llm/draft_guide.py is missing run_draft_guide_loop "
            "(sibling module not installed yet).",
            file=sys.stderr,
        )
        _print_grok_audit_excerpt(args.log)
        print("PASS/FAIL: FAIL")
        return 1

    args.log.parent.mkdir(parents=True, exist_ok=True)

    try:
        result = run_draft_guide_loop(
            task=args.task,
            max_rounds=args.max_rounds,
            log_path=args.log,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"PASS/FAIL: FAIL ({exc})", file=sys.stderr)
        _print_grok_audit_excerpt(args.log)
        return 1

    ok, reason = _evaluate_pass(result, args.log)
    if ok:
        print(f"PASS/FAIL: PASS ({reason})")
    else:
        print(f"PASS/FAIL: FAIL ({reason})", file=sys.stderr)
    _print_grok_audit_excerpt(args.log)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
