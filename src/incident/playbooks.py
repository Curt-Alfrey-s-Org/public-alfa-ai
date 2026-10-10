"""Incident playbook registry (YAML, investigate-only v1)."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)

_DEFAULT_PLAYBOOK_DIR = Path(__file__).resolve().parents[2] / "deploy" / "incident-playbooks"

# auto_fix steps must not touch inference/RPC containers (no-piecemeal-cluster-scripts.mdc).
_AUTO_FIX_BLOCKLIST = re.compile(
    r"(rpc-server|llamacpp-rpc|llamacpp-server|inference|pool-27|grev27|coordinator)",
    re.IGNORECASE,
)


@dataclass(slots=True)
class PlaybookStep:
    step_type: str
    name: str = ""
    url: str = ""
    path: str = ""
    args: list[str] = field(default_factory=list)
    timeout_sec: int = 60


@dataclass(slots=True)
class IncidentPlaybook:
    alertname: str
    description: str = ""
    investigate: list[PlaybookStep] = field(default_factory=list)
    auto_fix: list[PlaybookStep] = field(default_factory=list)


def _parse_step(raw: dict[str, Any]) -> PlaybookStep | None:
    if not isinstance(raw, dict):
        return None
    step_type = str(raw.get("type") or raw.get("step_type") or "").strip().lower()
    if not step_type:
        return None
    args_raw = raw.get("args")
    args = [str(a) for a in args_raw] if isinstance(args_raw, list) else []
    timeout_raw = raw.get("timeout_sec", 60)
    try:
        timeout_sec = int(timeout_raw)
    except (TypeError, ValueError):
        timeout_sec = 60
    return PlaybookStep(
        step_type=step_type,
        name=str(raw.get("name") or step_type),
        url=str(raw.get("url") or ""),
        path=str(raw.get("path") or ""),
        args=args,
        timeout_sec=max(5, min(timeout_sec, 600)),
    )


def _auto_fix_step_allowed(step: PlaybookStep) -> bool:
    """Reject auto_fix steps that reference inference/RPC piecemeal targets."""
    blob = " ".join([step.url, step.path, step.name, *step.args])
    return not _AUTO_FIX_BLOCKLIST.search(blob)


def _parse_playbook(raw: dict[str, Any]) -> IncidentPlaybook | None:
    alertname = str(raw.get("alertname") or "").strip()
    if not alertname:
        return None
    investigate: list[PlaybookStep] = []
    for item in raw.get("investigate") or []:
        step = _parse_step(item)
        if step:
            investigate.append(step)
    auto_fix: list[PlaybookStep] = []
    for item in raw.get("auto_fix") or []:
        step = _parse_step(item)
        if step and _auto_fix_step_allowed(step):
            auto_fix.append(step)
        elif step:
            logger.warning(
                "playbook %s: rejected auto_fix step %s (inference/RPC blocklist)",
                alertname,
                step.name or step.step_type,
            )
    return IncidentPlaybook(
        alertname=alertname,
        description=str(raw.get("description") or ""),
        investigate=investigate,
        auto_fix=auto_fix,
    )


def load_playbooks(playbook_dir: Path | None = None) -> dict[str, IncidentPlaybook]:
    root = playbook_dir or _DEFAULT_PLAYBOOK_DIR
    out: dict[str, IncidentPlaybook] = {}
    if not root.is_dir():
        logger.warning("incident playbook dir missing: %s", root)
        return out
    for path in sorted(root.glob("*.yaml")) + sorted(root.glob("*.yml")):
        try:
            raw = yaml.safe_load(path.read_text(encoding="utf-8"))
        except Exception:
            logger.exception("failed to load playbook %s", path)
            continue
        if not isinstance(raw, dict):
            continue
        playbook = _parse_playbook(raw)
        if playbook:
            out[playbook.alertname] = playbook
    return out


def get_playbook(alertname: str, playbook_dir: Path | None = None) -> IncidentPlaybook | None:
    return load_playbooks(playbook_dir).get(alertname)


def playbook_source_path(alertname: str, playbook_dir: Path | None = None) -> str | None:
    """Repo-relative path to the YAML file for alertname, if registered."""
    root = playbook_dir or _DEFAULT_PLAYBOOK_DIR
    repo_root = Path(__file__).resolve().parents[2]
    if not root.is_dir():
        return None
    for path in sorted(root.glob("*.yaml")) + sorted(root.glob("*.yml")):
        try:
            raw = yaml.safe_load(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(raw, dict):
            continue
        if str(raw.get("alertname") or "").strip() == alertname:
            try:
                return str(path.resolve().relative_to(repo_root.resolve())).replace("\\", "/")
            except ValueError:
                return str(path.name)
    return None
