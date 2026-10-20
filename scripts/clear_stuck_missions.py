#!/usr/bin/env python3
"""Clear wedged pending/running mission runs (L2 operator / brain host).

Does not touch inference. Prefer Ask ALFa Approve in production; this CLI is for
operators and automation on the brain host (docker exec alfa-ai-api).

Usage:
  python scripts/clear_stuck_missions.py
  python scripts/clear_stuck_missions.py --dry-run
  python scripts/clear_stuck_missions.py --json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[1]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from src.ops.mission_wedge import clear_stuck_missions, detect_mission_wedge, format_wedge_report  # noqa: E402
from src.runtime.store import run_to_dict, task_to_dict  # noqa: E402


def _wedge_before() -> dict:
    from src.runtime.factory import build_orchestrator

    orch = build_orchestrator()
    runs = [run_to_dict(r) for r in orch.store.list_runs()]
    tasks_by_run: dict[str, list] = {}
    for run in runs:
        rid = str(run.get("run_id") or "")
        if rid:
            tasks_by_run[rid] = [task_to_dict(t) for t in orch.store.list_tasks_for_run(rid)]
    return detect_mission_wedge(runs, tasks_by_run=tasks_by_run)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Clear wedged mission runs on brain")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--min-age-sec",
        type=int,
        default=None,
        help="Override ALFA_AI_MISSION_STUCK_SEC threshold",
    )
    args = parser.parse_args(argv)

    before = _wedge_before()
    result = clear_stuck_missions(min_age_sec=args.min_age_sec, dry_run=args.dry_run)
    result["wedge_report"] = format_wedge_report(before)

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=True))
    else:
        print(format_wedge_report(before))
        print()
        print(
            f"cleared_count={result.get('cleared_count')} dry_run={result.get('dry_run')}"
        )
        for row in result.get("cleared") or []:
            print(
                f"  - {row.get('run_id')} skill={row.get('skill')} "
                f"age_sec={row.get('age_sec')} cleared={row.get('cleared')}"
            )
        print(result.get("note") or "")

    cleared = int(result.get("cleared_count") or 0)
    if args.dry_run:
        return 0
    return 0 if cleared >= 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
