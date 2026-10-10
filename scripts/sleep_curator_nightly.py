#!/usr/bin/env python3
"""Nightly sleep curator entrypoint (learning-loop L2 / Tier A).

Usage:
  python scripts/sleep_curator_nightly.py
  python scripts/sleep_curator_nightly.py --dry-run
  python scripts/sleep_curator_nightly.py --require-enabled
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[1]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from src.runtime.sleep_curator import run_sleep_curator  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="ALFa sleep curator (Tier A)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--require-enabled",
        action="store_true",
        help="Exit 2 if ALFA_AI_SLEEP_CURATOR_ENABLED is off",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    report = run_sleep_curator(
        dry_run=args.dry_run,
        require_enabled_flag=args.require_enabled,
    )
    if args.json:
        print(json.dumps(report.to_dict(), indent=2, ensure_ascii=True))
    else:
        print(report.to_markdown())
    if not report.ok:
        return 2 if args.require_enabled else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
