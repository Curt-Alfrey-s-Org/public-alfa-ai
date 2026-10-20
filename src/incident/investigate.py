"""Run investigate-only playbook steps for an incident."""

from __future__ import annotations

import logging
import os
import subprocess
from pathlib import Path
from typing import Any

import httpx

from src.incident.playbooks import IncidentPlaybook, PlaybookStep

logger = logging.getLogger(__name__)

_REPO_ROOT = Path(__file__).resolve().parents[2]


def _run_http_step(step: PlaybookStep) -> dict[str, Any]:
    if not step.url:
        return {"ok": False, "error": "http step missing url"}
    try:
        with httpx.Client(timeout=float(step.timeout_sec)) as client:
            response = client.get(step.url)
        body_preview = (response.text or "")[:4000]
        return {
            "ok": response.status_code < 400,
            "status_code": response.status_code,
            "url": step.url,
            "body_preview": body_preview,
        }
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)[:500], "url": step.url}


def _run_script_step(step: PlaybookStep) -> dict[str, Any]:
    if not step.path:
        return {"ok": False, "error": "script step missing path"}
    script_path = (_REPO_ROOT / step.path).resolve()
    try:
        script_path.relative_to(_REPO_ROOT.resolve())
    except ValueError:
        return {"ok": False, "error": "script path escapes repo root"}

    if not script_path.is_file():
        return {"ok": False, "error": f"script not found: {step.path}"}

    if script_path.suffix == ".ps1":
        cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script_path), *step.args]
    else:
        cmd = ["bash", str(script_path), *step.args]

    try:
        completed = subprocess.run(
            cmd,
            cwd=str(_REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=step.timeout_sec,
            check=False,
        )
        return {
            "ok": completed.returncode == 0,
            "returncode": completed.returncode,
            "stdout": (completed.stdout or "")[:8000],
            "stderr": (completed.stderr or "")[:4000],
            "command": " ".join(cmd[:6]),
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "script timed out", "path": step.path}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)[:500], "path": step.path}


def run_playbook_steps(steps: list[PlaybookStep]) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for step in steps:
        if step.step_type == "http":
            result = _run_http_step(step)
        elif step.step_type == "script":
            result = _run_script_step(step)
        else:
            result = {"ok": False, "error": f"unknown step type: {step.step_type}"}
        results.append({"name": step.name or step.step_type, "type": step.step_type, "result": result})
    return results


def investigate_incident(playbook: IncidentPlaybook | None, alertname: str) -> dict[str, Any]:
    if playbook is None:
        return {
            "alertname": alertname,
            "playbook_matched": False,
            "steps": [],
            "summary": f"No playbook registered for alert {alertname}.",
        }

    step_results = run_playbook_steps(playbook.investigate)
    ok_count = sum(1 for item in step_results if item.get("result", {}).get("ok"))
    summary = (
        f"Playbook {playbook.alertname}: {ok_count}/{len(step_results)} investigate steps OK."
        if step_results
        else f"Playbook {playbook.alertname} has no investigate steps."
    )
    return {
        "alertname": alertname,
        "playbook_matched": True,
        "description": playbook.description,
        "steps": step_results,
        "summary": summary,
    }


def auto_fix_enabled() -> bool:
    return (os.getenv("ALFA_AI_INCIDENT_AUTO_FIX", "false").strip().lower() in ("1", "true", "yes", "on"))


def auto_fix_allowed_for_alert(alertname: str, settings: Any | None = None) -> bool:
    """L3 auto_fix requires global flag on AND alertname in allowlist (empty allowlist = none)."""
    if not auto_fix_enabled():
        return False
    raw = ""
    if settings is not None:
        try:
            raw = str(settings.get("auto_fix_allowlist", "") or "")
        except Exception:
            raw = ""
    if not raw.strip():
        raw = os.getenv("ALFA_AI_INCIDENT_AUTO_FIX_ALLOWLIST", "") or ""
    allowed = {name.strip() for name in raw.split(",") if name.strip()}
    return bool(allowed) and alertname in allowed
