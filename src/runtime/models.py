from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any, Literal

RunStatus = Literal["pending", "running", "done", "failed"]
TaskStatus = Literal["pending", "ready", "running", "done", "failed", "blocked", "cancelled"]


def now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


@dataclass(slots=True)
class RunRecord:
    run_id: str
    goal: str
    status: RunStatus = "pending"
    skill: str = ""
    research_only: bool = False
    workflow: str = ""
    target_host: str = "111"
    created_at: str = field(default_factory=now_iso)
    updated_at: str = field(default_factory=now_iso)


@dataclass(slots=True)
class TaskRecord:
    task_id: str
    run_id: str
    role: str
    title: str
    status: TaskStatus = "pending"
    metadata: dict[str, Any] = field(default_factory=dict)
    created_at: str = field(default_factory=now_iso)
    updated_at: str = field(default_factory=now_iso)


@dataclass(slots=True)
class ArtifactRecord:
    artifact_id: str
    run_id: str
    task_id: str
    artifact_type: str
    path: str
    sha256: str
    metadata: dict[str, Any] = field(default_factory=dict)
    created_at: str = field(default_factory=now_iso)

