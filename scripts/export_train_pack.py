#!/usr/bin/env python3
"""Export L3 training pack for alfa-train (no GPU train).

Usage:
  python scripts/export_train_pack.py
  python scripts/export_train_pack.py --json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[1]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))

from src.runtime.train_export import export_train_pack  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Export alfa-ai train pack for alfa-train")
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--skip-preference-refresh",
        action="store_true",
        help="Do not re-run preference export from feedback inbox",
    )
    args = parser.parse_args(argv)
    report = export_train_pack(run_preference_export=not args.skip_preference_refresh)
    if args.json:
        print(json.dumps(report.to_dict(), indent=2, ensure_ascii=True))
    else:
        print(f"ok={report.ok}")
        print(f"export_dir={report.export_dir}")
        print(f"hub_hint={report.hub_hint}")
        for k, v in report.counts.items():
            print(f"  {k}={v}")
        for note in report.notes:
            print(f"  note: {note}")
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
