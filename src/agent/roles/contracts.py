from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal


RoleStatus = Literal["success", "needs_input", "blocked", "failed"]


@dataclass(slots=True)
class ArtifactRef:
    artifact_id: str
    artifact_type: str
    path: str
    sha256: str
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(slots=True)
class ToolEvent:
    tool_name: str
    ok: bool
    started_at: str
    duration_ms: int
    details: dict[str, Any] = field(default_factory=dict)


@dataclass(slots=True)
class RoleRequest:
    run_id: str
    task_id: str
    role: str
    goal: str
    inputs: dict[str, Any] = field(default_factory=dict)
    context: dict[str, Any] = field(default_factory=dict)
    constraints: dict[str, Any] = field(default_factory=dict)
    budget: dict[str, Any] = field(default_factory=dict)


@dataclass(slots=True)
class RoleResponse:
    status: RoleStatus
    summary: str
    artifacts: list[ArtifactRef] = field(default_factory=list)
    tool_events: list[ToolEvent] = field(default_factory=list)
    metrics: dict[str, Any] = field(default_factory=dict)
    next_actions: list[str] = field(default_factory=list)

