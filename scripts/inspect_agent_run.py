"""One-off: print agent run task summary and artifact paths (brain container)."""

from __future__ import annotations

import sys

from src.runtime.factory import build_orchestrator


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: python scripts/inspect_agent_run.py <run_id>", file=sys.stderr)
        return 2
    run_id = sys.argv[1].strip()
    o = build_orchestrator()
    run = o.store.get_run(run_id)
    if run is None:
        print(f"run not found: {run_id}")
        return 1
    print("RUN", run)
    tasks = o.store.list_tasks_for_run(run_id)
    for task in tasks:
        print("TASK", task)
    arts = o.store.list_artifacts_for_run(run_id)
    for art in arts:
        print("ARTIFACT", art)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
