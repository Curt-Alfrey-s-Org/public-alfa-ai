#!/usr/bin/env python3
"""Export completed agent audit artifacts to hub log files for later review.

Appends one section per run to:
  {ALFA_AI_AUDIT_LOG_DIR}/findings-YYYY-MM-DD.md
  {ALFA_AI_AUDIT_LOG_DIR}/findings.jsonl

Tracks exported run_ids in {ALFA_AI_AUDIT_LOG_DIR}/exported-runs.json.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

_REPO = Path(__file__).resolve().parents[1]


def _api_json(url: str, token: str, *, method: str = "GET", body: dict | None = None) -> object:
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def _load_token(env_file: str | None) -> str:
    token = os.environ.get("ALFA_TOKEN", "").strip()
    if token:
        return token
    path = env_file or os.environ.get("ALFA_AI_ENV_FILE", "")
    if not path:
        return ""
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.startswith("ALFA_AI_API_TOKEN="):
            return line.split("=", 1)[1].strip().strip("\r")
    return ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Export agent audit findings to hub logs")
    parser.add_argument("--api", default=os.environ.get("ALFA_API", "http://127.0.0.1:8420"))
    parser.add_argument("--env-file", default=os.environ.get("ALFA_AI_ENV_FILE", ""))
    parser.add_argument(
        "--log-dir",
        default=os.environ.get("ALFA_AI_AUDIT_LOG_DIR", "/mnt/hub/alfa-ai/agent-audit-logs"),
    )
    parser.add_argument("--json", action="store_true", help="Print summary JSON to stdout")
    args = parser.parse_args(argv)

    token = _load_token(args.env_file or None)
    if not token:
        print("Set ALFA_TOKEN or --env-file with ALFA_AI_API_TOKEN", file=sys.stderr)
        return 2

    log_dir = Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    state_path = log_dir / "exported-runs.json"
    exported: set[str] = set()
    if state_path.is_file():
        exported = set(json.loads(state_path.read_text(encoding="utf-8")))

    runs = _api_json(f"{args.api.rstrip('/')}/api/runs", token)
    if not isinstance(runs, list):
        print("unexpected /api/runs response", file=sys.stderr)
        return 1

    today = datetime.now(tz=UTC).strftime("%Y-%m-%d")
    md_path = log_dir / f"findings-{today}.md"
    jsonl_path = log_dir / "findings.jsonl"
    new_exports = 0

    for run_summary in runs:
        if not isinstance(run_summary, dict):
            continue
        run_id = str(run_summary.get("run_id") or "")
        status = str(run_summary.get("status") or "")
        if not run_id or status not in ("done", "failed"):
            continue
        if run_id in exported:
            continue

        detail = _api_json(f"{args.api.rstrip('/')}/api/runs/{run_id}", token)
        if not isinstance(detail, dict) or not detail.get("ok"):
            continue

        run = detail.get("run") or {}
        artifacts = detail.get("artifacts") or []
        goal = str(run.get("goal") or run_summary.get("goal") or "")
        skill = ""
        target_host = "111"
        tasks = detail.get("tasks") or []
        if isinstance(tasks, list) and tasks:
            meta = tasks[0].get("metadata") if isinstance(tasks[0], dict) else {}
            if isinstance(meta, dict):
                skill = str(meta.get("skill") or "")
                target_host = str(meta.get("target_host") or target_host)

        bodies: list[str] = []
        for art in artifacts:
            if not isinstance(art, dict):
                continue
            art_id = str(art.get("artifact_id") or "")
            if not art_id:
                continue
            try:
                content_resp = _api_json(
                    f"{args.api.rstrip('/')}/api/runs/{run_id}/artifacts/{art_id}/content",
                    token,
                )
            except urllib.error.HTTPError:
                continue
            if not isinstance(content_resp, dict) or not content_resp.get("ok"):
                continue
            path = str(content_resp.get("path") or art.get("path") or "")
            text = str(content_resp.get("content") or "")
            if text.strip():
                bodies.append(f"### Artifact: {path}\n\n{text.strip()}\n")

        if not bodies:
            bodies.append("_No artifact text exported (run may have failed early)._")

        section = (
            f"\n\n---\n\n## Run {run_id}\n"
            f"- status: {status}\n"
            f"- skill: {skill or '(inferred)'}\n"
            f"- target_host: {target_host}\n"
            f"- goal: {goal}\n"
            f"- exported_at: {datetime.now(tz=UTC).isoformat()}\n\n"
            + "\n".join(bodies)
        )
        with md_path.open("a", encoding="utf-8") as md_f:
            md_f.write(section)

        record = {
            "run_id": run_id,
            "status": status,
            "skill": skill,
            "target_host": target_host,
            "goal": goal,
            "exported_at": datetime.now(tz=UTC).isoformat(),
            "artifact_count": len(artifacts),
            "markdown_path": str(md_path),
        }
        with jsonl_path.open("a", encoding="utf-8") as jl_f:
            jl_f.write(json.dumps(record, ensure_ascii=True) + "\n")

        exported.add(run_id)
        new_exports += 1

    state_path.write_text(json.dumps(sorted(exported), indent=2), encoding="utf-8")
    summary = {
        "ok": True,
        "new_exports": new_exports,
        "log_dir": str(log_dir),
        "markdown": str(md_path),
        "jsonl": str(jsonl_path),
    }
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(
            f"export_audit_findings: new_exports={new_exports} "
            f"md={md_path} jsonl={jsonl_path}"
        )
    try:
        if str(_REPO) not in sys.path:
            sys.path.insert(0, str(_REPO))
        from src.ops.mission_heartbeat import write_heartbeat

        write_heartbeat(
            log_dir,
            "export-findings",
            status="alive",
            last_action=f"export ok new_exports={new_exports}",
        )
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
