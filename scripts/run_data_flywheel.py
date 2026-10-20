#!/usr/bin/env python3
"""Run data flywheel MAPE Tier A (monitor, analyze, plan).

Usage:
  python scripts/run_data_flywheel.py
  python scripts/run_data_flywheel.py --dry-run
  python scripts/run_data_flywheel.py --require-enabled

After export on hub, hub publish runs on the host (not in container):
  bash scripts/publish_train_pack_to_hub.sh
  # or: bash scripts/learning_loop_tier_a.sh (includes publish unless --skip-publish)
"""

from __future__ import annotations

import argparse
import json
import sys

from src.runtime.flywheel import flywheel_enabled, run_data_flywheel


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="ALFa data flywheel (MAPE Tier A)")
    parser.add_argument("--dry-run", action="store_true", help="Monitor only; skip curator and export")
    parser.add_argument("--skip-curator", action="store_true")
    parser.add_argument("--skip-export", action="store_true")
    parser.add_argument(
        "--require-enabled",
        action="store_true",
        help="Exit 2 unless ALFA_AI_FLYWHEEL_ENABLED=1",
    )
    args = parser.parse_args(argv)

    if args.require_enabled and not flywheel_enabled():
        print("ALFA_AI_FLYWHEEL_ENABLED is not set; skipping", file=sys.stderr)
        return 2

    report = run_data_flywheel(
        dry_run=args.dry_run,
        skip_curator=args.skip_curator,
        skip_export=args.skip_export,
    )
    print(json.dumps(report.to_dict(), indent=2, ensure_ascii=True))
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
