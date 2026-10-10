#!/usr/bin/env python3
"""Judge exported audit findings and write Cursor review handoff.

Reads {ALFA_AI_AUDIT_LOG_DIR}/findings-YYYY-MM-DD.md, dual-checks each finding
via independent judge (ALFA_AI_JUDGE_*), writes judged.jsonl and cursor-review-*.md.

Usage:
  ALFA_AI_ENV_FILE=deploy/.env python3 scripts/judge_audit_findings.py
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[1]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Judge audit findings and build Cursor handoff")
    parser.add_argument(
        "--log-dir",
        default=os.environ.get("ALFA_AI_AUDIT_LOG_DIR", "/mnt/hub/alfa-ai/agent-audit-logs"),
    )
    parser.add_argument("--env-file", default=os.environ.get("ALFA_AI_ENV_FILE", ""))
    parser.add_argument("--date", default="", help="YYYY-MM-DD (default: today UTC)")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    if str(_REPO) not in sys.path:
        sys.path.insert(0, str(_REPO))

    if args.env_file:
        from src.ops.audit_judge import load_env_file

        load_env_file(args.env_file)

    from src.ops.audit_judge import run_audit_judge

    summary = run_audit_judge(
        Path(args.log_dir),
        date_label=args.date or None,
    )
    try:
        from src.ops.mission_heartbeat import write_heartbeat

        new_judged = int(summary.get("new_judged") or 0)
        write_heartbeat(
            Path(args.log_dir),
            "judge-findings",
            status="alive" if summary.get("ok") else "idle",
            last_action=f"judge new_judged={new_judged}",
        )
    except Exception:
        pass
    if args.json:
        print(json.dumps(summary, indent=2, ensure_ascii=True))
    else:
        print(
            f"judge_audit_findings: new_judged={summary.get('new_judged', 0)} "
            f"cursor={summary.get('cursor_review', '')}"
        )
    return 0 if summary.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
