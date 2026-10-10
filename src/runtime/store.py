from __future__ import annotations

import json
from dataclasses import asdict
from datetime import UTC, datetime
from typing import Protocol

import psycopg
from psycopg.rows import dict_row

from src.runtime.models import ArtifactRecord, RunRecord, TaskRecord


def _now() -> str:
    return datetime.now(tz=UTC).isoformat()


def _budget_to_metadata(budget: object) -> dict:
    if budget is None:
        return {}
    if isinstance(budget, dict):
        return dict(budget)
    if isinstance(budget, str):
        try:
            parsed = json.loads(budget)
        except json.JSONDecodeError:
            return {}
        return dict(parsed) if isinstance(parsed, dict) else {}
    return {}


class RuntimeStore(Protocol):
    def create_run(self, run: RunRecord) -> None: ...
    def get_run(self, run_id: str) -> RunRecord | None: ...
    def list_runs(self) -> list[RunRecord]: ...
    def update_run_status(self, run_id: str, status: str) -> None: ...
    def create_task(self, task: TaskRecord) -> None: ...
    def add_dependency(self, task_id: str, depends_on_task_id: str) -> None: ...
    def get_task(self, task_id: str) -> TaskRecord | None: ...
    def list_tasks_for_run(self, run_id: str) -> list[TaskRecord]: ...
    def update_task_status(self, task_id: str, status: str) -> None: ...
    def list_dependents(self, task_id: str) -> list[str]: ...
    def dependencies_done(self, task_id: str) -> bool: ...
    def create_artifact(self, artifact: ArtifactRecord) -> None: ...
    def list_artifacts_for_run(self, run_id: str) -> list[ArtifactRecord]: ...
    def list_artifacts_for_task(self, task_id: str) -> list[ArtifactRecord]: ...


class InMemoryStore:
    def __init__(self) -> None:
        self.runs: dict[str, RunRecord] = {}
        self.tasks: dict[str, TaskRecord] = {}
        self.depends_on: dict[str, set[str]] = {}
        self.dependents: dict[str, set[str]] = {}
        self.artifacts: dict[str, ArtifactRecord] = {}

    def create_run(self, run: RunRecord) -> None:
        self.runs[run.run_id] = run

    def get_run(self, run_id: str) -> RunRecord | None:
        return self.runs.get(run_id)

    def list_runs(self) -> list[RunRecord]:
        return sorted(self.runs.values(), key=lambda item: item.created_at)

    def update_run_status(self, run_id: str, status: str) -> None:
        run = self.runs[run_id]
        run.status = status  # type: ignore[assignment]
        run.updated_at = _now()

    def create_task(self, task: TaskRecord) -> None:
        self.tasks[task.task_id] = task
        self.depends_on.setdefault(task.task_id, set())

    def add_dependency(self, task_id: str, depends_on_task_id: str) -> None:
        self.depends_on.setdefault(task_id, set()).add(depends_on_task_id)
        self.dependents.setdefault(depends_on_task_id, set()).add(task_id)

    def get_task(self, task_id: str) -> TaskRecord | None:
        return self.tasks.get(task_id)

    def list_tasks_for_run(self, run_id: str) -> list[TaskRecord]:
        return [task for task in self.tasks.values() if task.run_id == run_id]

    def update_task_status(self, task_id: str, status: str) -> None:
        task = self.tasks[task_id]
        task.status = status  # type: ignore[assignment]
        task.updated_at = _now()

    def list_dependents(self, task_id: str) -> list[str]:
        return sorted(self.dependents.get(task_id, set()))

    def dependencies_done(self, task_id: str) -> bool:
        needed = self.depends_on.get(task_id, set())
        for dep_id in needed:
            dep_task = self.tasks.get(dep_id)
            if dep_task is None or dep_task.status != "done":
                return False
        return True

    def create_artifact(self, artifact: ArtifactRecord) -> None:
        self.artifacts[artifact.artifact_id] = artifact

    def list_artifacts_for_run(self, run_id: str) -> list[ArtifactRecord]:
        return [artifact for artifact in self.artifacts.values() if artifact.run_id == run_id]

    def list_artifacts_for_task(self, task_id: str) -> list[ArtifactRecord]:
        return [artifact for artifact in self.artifacts.values() if artifact.task_id == task_id]


class PostgresStore:
    def __init__(self, database_url: str) -> None:
        self.database_url = database_url

    def _conn(self) -> psycopg.Connection:
        return psycopg.connect(self.database_url, row_factory=dict_row)

    def create_run(self, run: RunRecord) -> None:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO runs (id, user_goal, status, created_at, updated_at)
                VALUES (%s, %s, %s, NOW(), NOW())
                """,
                (run.run_id, run.goal, run.status),
            )

    def get_run(self, run_id: str) -> RunRecord | None:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT id, user_goal, status, created_at, updated_at FROM runs WHERE id = %s", (run_id,))
            row = cur.fetchone()
        if row is None:
            return None
        return RunRecord(
            run_id=str(row["id"]),
            goal=str(row["user_goal"]),
            status=row["status"],
            created_at=row["created_at"].isoformat(),
            updated_at=row["updated_at"].isoformat(),
        )

    def list_runs(self) -> list[RunRecord]:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT id, user_goal, status, created_at, updated_at FROM runs ORDER BY created_at ASC")
            rows = cur.fetchall()
        return [
            RunRecord(
                run_id=str(row["id"]),
                goal=str(row["user_goal"]),
                status=row["status"],
                created_at=row["created_at"].isoformat(),
                updated_at=row["updated_at"].isoformat(),
            )
            for row in rows
        ]

    def update_run_status(self, run_id: str, status: str) -> None:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute("UPDATE runs SET status = %s, updated_at = NOW() WHERE id = %s", (status, run_id))

    def create_task(self, task: TaskRecord) -> None:
        budget = json.dumps(task.metadata or {}, ensure_ascii=True)
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO tasks (id, run_id, role, title, status, budget, created_at, updated_at)
                VALUES (%s, %s, %s, %s, %s, %s::jsonb, NOW(), NOW())
                """,
                (
                    task.task_id,
                    task.run_id,
                    task.role,
                    task.title,
                    task.status,
                    budget,
                ),
            )

    def add_dependency(self, task_id: str, depends_on_task_id: str) -> None:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO task_dependencies (task_id, depends_on_task_id)
                VALUES (%s, %s)
                ON CONFLICT DO NOTHING
                """,
                (task_id, depends_on_task_id),
            )

    def get_task(self, task_id: str) -> TaskRecord | None:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT id, run_id, role, title, status, budget, created_at, updated_at "
                "FROM tasks WHERE id = %s",
                (task_id,),
            )
            row = cur.fetchone()
        if row is None:
            return None
        return TaskRecord(
            task_id=str(row["id"]),
            run_id=str(row["run_id"]),
            role=str(row["role"]),
            title=str(row["title"]),
            status=row["status"],
            metadata=_budget_to_metadata(row.get("budget")),
            created_at=row["created_at"].isoformat(),
            updated_at=row["updated_at"].isoformat(),
        )

    def list_tasks_for_run(self, run_id: str) -> list[TaskRecord]:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT id, run_id, role, title, status, budget, created_at, updated_at "
                "FROM tasks WHERE run_id = %s ORDER BY created_at ASC",
                (run_id,),
            )
            rows = cur.fetchall()
        return [
            TaskRecord(
                task_id=str(row["id"]),
                run_id=str(row["run_id"]),
                role=str(row["role"]),
                title=str(row["title"]),
                status=row["status"],
                metadata=_budget_to_metadata(row.get("budget")),
                created_at=row["created_at"].isoformat(),
                updated_at=row["updated_at"].isoformat(),
            )
            for row in rows
        ]

    def update_task_status(self, task_id: str, status: str) -> None:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute("UPDATE tasks SET status = %s, updated_at = NOW() WHERE id = %s", (status, task_id))

    def list_dependents(self, task_id: str) -> list[str]:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT task_id FROM task_dependencies WHERE depends_on_task_id = %s", (task_id,))
            rows = cur.fetchall()
        return [str(row["task_id"]) for row in rows]

    def dependencies_done(self, task_id: str) -> bool:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT COUNT(*) AS total,
                       COUNT(*) FILTER (WHERE t.status = 'done') AS done_count
                FROM task_dependencies d
                JOIN tasks t ON t.id = d.depends_on_task_id
                WHERE d.task_id = %s
                """,
                (task_id,),
            )
            row = cur.fetchone()
        if row is None:
            return True
        return int(row["total"]) == int(row["done_count"])

    def create_artifact(self, artifact: ArtifactRecord) -> None:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO artifacts (id, run_id, task_id, artifact_type, path, sha256, metadata, created_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s::jsonb, %s)
                """,
                (
                    artifact.artifact_id,
                    artifact.run_id,
                    artifact.task_id,
                    artifact.artifact_type,
                    artifact.path,
                    artifact.sha256,
                    json.dumps(artifact.metadata),
                    artifact.created_at,
                ),
            )

    def list_artifacts_for_run(self, run_id: str) -> list[ArtifactRecord]:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, run_id, task_id, artifact_type, path, sha256, metadata, created_at
                FROM artifacts
                WHERE run_id = %s
                ORDER BY created_at ASC
                """,
                (run_id,),
            )
            rows = cur.fetchall()
        return [
            ArtifactRecord(
                artifact_id=str(row["id"]),
                run_id=str(row["run_id"]),
                task_id=str(row["task_id"]),
                artifact_type=str(row["artifact_type"]),
                path=str(row["path"]),
                sha256=str(row["sha256"]),
                metadata=row.get("metadata", {}),
                created_at=row["created_at"].isoformat(),
            )
            for row in rows
        ]

    def list_artifacts_for_task(self, task_id: str) -> list[ArtifactRecord]:
        with self._conn() as conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, run_id, task_id, artifact_type, path, sha256, metadata, created_at
                FROM artifacts
                WHERE task_id = %s
                ORDER BY created_at ASC
                """,
                (task_id,),
            )
            rows = cur.fetchall()
        return [
            ArtifactRecord(
                artifact_id=str(row["id"]),
                run_id=str(row["run_id"]),
                task_id=str(row["task_id"]),
                artifact_type=str(row["artifact_type"]),
                path=str(row["path"]),
                sha256=str(row["sha256"]),
                metadata=row.get("metadata", {}),
                created_at=row["created_at"].isoformat(),
            )
            for row in rows
        ]


def run_to_dict(run: RunRecord) -> dict[str, str]:
    return asdict(run)


def task_to_dict(task: TaskRecord) -> dict[str, object]:
    return asdict(task)


def artifact_to_dict(artifact: ArtifactRecord) -> dict[str, object]:
    return asdict(artifact)

