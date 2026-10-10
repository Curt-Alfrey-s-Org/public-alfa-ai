"""Incident persistence for Alertmanager-driven cluster alerts."""

from __future__ import annotations

import json
import logging
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any, Literal

import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)

IncidentStatus = Literal[
    "received",
    "investigating",
    "remediation_attempted",
    "resolved",
    "needs_human",
]

_ACTIVE_STATUSES: frozenset[str] = frozenset(
    {"received", "investigating", "remediation_attempted", "needs_human"}
)

_ASK_ALFA_RECENT_INCIDENT_LIMIT = 8


def build_ask_alfa_incident_context(
    records: list[IncidentRecord],
    *,
    recent_limit: int = _ASK_ALFA_RECENT_INCIDENT_LIMIT,
) -> dict[str, Any]:
    """Shape incident rows for Ask ALFa.

    ``IncidentStore.list_incidents()`` without ``status`` returns newest-first
    rows of **any** status (a row sample, not a clock window). Do not treat
    that sample as currently firing or as "last N hours", and do not put
    resolved ``alertname`` values in ``recent_alertnames``.
    Live firing alerts belong in ``prometheus_ops.firing_alerts``.
    """
    safe_limit = max(1, min(int(recent_limit), 50))
    window_by_status: dict[str, int] = {}
    open_by_status: dict[str, int] = {}
    open_alertnames: list[str] = []
    recent: list[dict[str, Any]] = []
    for inc in records:
        window_by_status[inc.status] = window_by_status.get(inc.status, 0) + 1
        if inc.status in _ACTIVE_STATUSES:
            open_by_status[inc.status] = open_by_status.get(inc.status, 0) + 1
            if len(open_alertnames) < safe_limit:
                open_alertnames.append(inc.alertname)
        if len(recent) < safe_limit:
            recent.append(
                {
                    "alertname": inc.alertname,
                    "status": inc.status,
                    "severity": inc.severity,
                    "opened_at": inc.opened_at,
                }
            )
    return {
        "incident_counts_in_window": window_by_status,
        "incident_window_kind": "last_n_rows",
        "incident_window_row_limit": len(records),
        "open_incidents_by_status": open_by_status,
        "open_incident_alertnames": open_alertnames,
        "recent_alertnames": list(open_alertnames),
        "recent_incidents": recent,
    }


def _now_iso() -> str:
    return datetime.now(tz=UTC).isoformat()


@dataclass(slots=True)
class IncidentRecord:
    id: str
    fingerprint: str
    alertname: str
    severity: str
    status: IncidentStatus
    labels: dict[str, Any]
    annotations: dict[str, Any]
    raw_payload: dict[str, Any]
    summary: str | None
    opened_at: str
    resolved_at: str | None
    last_seen_at: str
    updated_at: str
    created_at: str = field(default_factory=_now_iso)


@dataclass(slots=True)
class IncidentEventRecord:
    id: str
    incident_id: str
    event_type: str
    payload: dict[str, Any]
    created_at: str


RemediationClassification = Literal["alert_tuning", "code_fix", "ops_action"]
RemediationStatus = Literal["proposed", "applied", "dismissed"]


@dataclass(slots=True)
class IncidentRemediationRecord:
    id: str
    incident_id: str
    classification: RemediationClassification
    root_cause: str
    confidence: str
    target_repo: str
    target_path: str | None
    proposed_change: str
    rationale: str | None
    briefing: dict[str, Any] | None
    status: RemediationStatus
    pr_url: str | None
    created_by: str | None
    created_at: str


_CREATE_INCIDENTS_TABLE = """\
CREATE TABLE IF NOT EXISTS incidents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fingerprint TEXT NOT NULL,
    alertname TEXT NOT NULL DEFAULT 'unknown',
    severity TEXT NOT NULL DEFAULT 'unknown',
    status TEXT NOT NULL DEFAULT 'received'
        CHECK (status IN (
            'received', 'investigating', 'remediation_attempted',
            'resolved', 'needs_human'
        )),
    labels JSONB NOT NULL DEFAULT '{}'::jsonb,
    annotations JSONB NOT NULL DEFAULT '{}'::jsonb,
    raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    summary TEXT,
    opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_incidents_fingerprint ON incidents (fingerprint);
CREATE INDEX IF NOT EXISTS idx_incidents_status ON incidents (status);
CREATE INDEX IF NOT EXISTS idx_incidents_opened_at ON incidents (opened_at DESC);

CREATE TABLE IF NOT EXISTS incident_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    incident_id UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_incident_events_incident_id
    ON incident_events (incident_id, created_at);

CREATE TABLE IF NOT EXISTS incident_remediations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    incident_id UUID NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    classification TEXT NOT NULL
        CHECK (classification IN ('alert_tuning', 'code_fix', 'ops_action')),
    root_cause TEXT NOT NULL DEFAULT '',
    confidence TEXT NOT NULL DEFAULT 'medium',
    target_repo TEXT NOT NULL DEFAULT '',
    target_path TEXT,
    proposed_change TEXT NOT NULL DEFAULT '',
    rationale TEXT,
    status TEXT NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('proposed', 'applied', 'dismissed')),
    pr_url TEXT,
    created_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_incident_remediations_incident_id
    ON incident_remediations (incident_id, created_at DESC);
"""


def _row_to_incident(row: dict[str, Any]) -> IncidentRecord:
    return IncidentRecord(
        id=str(row["id"]),
        fingerprint=row["fingerprint"],
        alertname=row["alertname"],
        severity=row["severity"],
        status=row["status"],
        labels=row.get("labels") or {},
        annotations=row.get("annotations") or {},
        raw_payload=row.get("raw_payload") or {},
        summary=row.get("summary"),
        opened_at=row["opened_at"].isoformat() if hasattr(row["opened_at"], "isoformat") else str(row["opened_at"]),
        resolved_at=(
            row["resolved_at"].isoformat()
            if row.get("resolved_at") and hasattr(row["resolved_at"], "isoformat")
            else (str(row["resolved_at"]) if row.get("resolved_at") else None)
        ),
        last_seen_at=(
            row["last_seen_at"].isoformat()
            if hasattr(row["last_seen_at"], "isoformat")
            else str(row["last_seen_at"])
        ),
        updated_at=(
            row["updated_at"].isoformat()
            if hasattr(row["updated_at"], "isoformat")
            else str(row["updated_at"])
        ),
        created_at=(
            row["created_at"].isoformat()
            if hasattr(row["created_at"], "isoformat")
            else str(row["created_at"])
        ),
    )


class IncidentStore:
    """Postgres persistence for incidents and timeline events."""

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_tables()

    def _conn(self):
        from src.api.db_pool import db_connection
        return db_connection(self.database_url)

    def _ensure_tables(self) -> None:
        try:
            with self._conn() as conn:
                conn.execute(_CREATE_INCIDENTS_TABLE)
                conn.execute(
                    """
                    ALTER TABLE incident_remediations
                    ADD COLUMN IF NOT EXISTS briefing_json JSONB
                    """
                )
                conn.commit()
        except Exception:
            logger.exception("Failed to ensure incidents tables")
            raise

    def count_by_status(self) -> dict[str, int]:
        with self._conn() as conn:
            rows = conn.execute(
                """
                SELECT status, count(*) AS cnt FROM incidents
                GROUP BY status
                """
            ).fetchall()
        return {str(row["status"]): int(row["cnt"]) for row in rows}

    def oldest_active_lag_seconds(self) -> float | None:
        """Seconds since oldest received/investigating incident opened_at."""
        with self._conn() as conn:
            row = conn.execute(
                """
                SELECT opened_at FROM incidents
                WHERE status IN ('received', 'investigating')
                ORDER BY opened_at ASC
                LIMIT 1
                """
            ).fetchone()
        if not row or not row.get("opened_at"):
            return None
        opened = row["opened_at"]
        if not isinstance(opened, datetime):
            return None
        if opened.tzinfo is None:
            opened = opened.replace(tzinfo=UTC)
        return max(0.0, (datetime.now(tz=UTC) - opened).total_seconds())

    def record_event(
        self,
        incident_id: str,
        event_type: str,
        payload: dict[str, Any] | None = None,
    ) -> IncidentEventRecord:
        event_id = str(uuid.uuid4())
        body = payload or {}
        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO incident_events (id, incident_id, event_type, payload)
                VALUES (%s, %s, %s, %s::jsonb)
                """,
                (event_id, incident_id, event_type, json.dumps(body)),
            )
            conn.commit()
        return IncidentEventRecord(
            id=event_id,
            incident_id=incident_id,
            event_type=event_type,
            payload=body,
            created_at=_now_iso(),
        )

    def upsert_from_alert(
        self,
        *,
        fingerprint: str,
        alertname: str,
        severity: str,
        alert_status: str,
        labels: dict[str, Any],
        annotations: dict[str, Any],
        raw_alert: dict[str, Any],
    ) -> tuple[IncidentRecord, bool]:
        """Insert or update incident. Returns (record, is_new_firing)."""
        now = _now_iso()
        summary = (annotations.get("summary") or annotations.get("description") or "").strip() or None
        is_resolved = alert_status == "resolved"
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM incidents WHERE fingerprint = %s",
                (fingerprint,),
            ).fetchone()

            if row is None:
                incident_id = str(uuid.uuid4())
                status: IncidentStatus = "resolved" if is_resolved else "received"
                conn.execute(
                    """
                    INSERT INTO incidents (
                        id, fingerprint, alertname, severity, status,
                        labels, annotations, raw_payload, summary,
                        opened_at, resolved_at, last_seen_at, updated_at
                    )
                    VALUES (
                        %s, %s, %s, %s, %s,
                        %s::jsonb, %s::jsonb, %s::jsonb, %s,
                        NOW(), %s, NOW(), NOW()
                    )
                    """,
                    (
                        incident_id,
                        fingerprint,
                        alertname,
                        severity,
                        status,
                        json.dumps(labels),
                        json.dumps(annotations),
                        json.dumps(raw_alert),
                        summary,
                        now if is_resolved else None,
                    ),
                )
                conn.commit()
                is_new = not is_resolved
                incident = self.get_by_id(incident_id)
                assert incident is not None
                return incident, is_new

            incident_id = str(row["id"])
            if is_resolved:
                conn.execute(
                    """
                    UPDATE incidents SET
                        status = 'resolved',
                        resolved_at = COALESCE(resolved_at, NOW()),
                        last_seen_at = NOW(),
                        updated_at = NOW(),
                        raw_payload = %s::jsonb,
                        annotations = %s::jsonb,
                        labels = %s::jsonb
                    WHERE id = %s
                    """,
                    (
                        json.dumps(raw_alert),
                        json.dumps(annotations),
                        json.dumps(labels),
                        incident_id,
                    ),
                )
                conn.commit()
                incident = self.get_by_id(incident_id)
                assert incident is not None
                return incident, False

            conn.execute(
                """
                UPDATE incidents SET
                    alertname = %s,
                    severity = %s,
                    status = CASE
                        WHEN status = 'resolved' THEN 'received'
                        ELSE status
                    END,
                    resolved_at = NULL,
                    labels = %s::jsonb,
                    annotations = %s::jsonb,
                    raw_payload = %s::jsonb,
                    summary = COALESCE(%s, summary),
                    last_seen_at = NOW(),
                    updated_at = NOW()
                WHERE id = %s
                """,
                (
                    alertname,
                    severity,
                    json.dumps(labels),
                    json.dumps(annotations),
                    json.dumps(raw_alert),
                    summary,
                    incident_id,
                ),
            )
            conn.commit()
            was_resolved = row["status"] == "resolved"
            incident = self.get_by_id(incident_id)
            assert incident is not None
            return incident, was_resolved

    def get_by_id(self, incident_id: str) -> IncidentRecord | None:
        from src.api.uuid_util import parse_uuid

        uid = parse_uuid(incident_id)
        if uid is None:
            return None
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM incidents WHERE id = %s",
                (uid,),
            ).fetchone()
        return _row_to_incident(row) if row else None

    def list_incidents(
        self,
        *,
        status: str | None = None,
        limit: int = 50,
    ) -> list[IncidentRecord]:
        safe_limit = max(1, min(limit, 200))
        with self._conn() as conn:
            if status:
                rows = conn.execute(
                    """
                    SELECT * FROM incidents
                    WHERE status = %s
                    ORDER BY opened_at DESC
                    LIMIT %s
                    """,
                    (status, safe_limit),
                ).fetchall()
            else:
                rows = conn.execute(
                    """
                    SELECT * FROM incidents
                    ORDER BY opened_at DESC
                    LIMIT %s
                    """,
                    (safe_limit,),
                ).fetchall()
        return [_row_to_incident(row) for row in rows]

    def list_events(self, incident_id: str, limit: int = 100) -> list[IncidentEventRecord]:
        safe_limit = max(1, min(limit, 500))
        with self._conn() as conn:
            rows = conn.execute(
                """
                SELECT * FROM incident_events
                WHERE incident_id = %s
                ORDER BY created_at ASC
                LIMIT %s
                """,
                (incident_id, safe_limit),
            ).fetchall()
        out: list[IncidentEventRecord] = []
        for row in rows:
            out.append(
                IncidentEventRecord(
                    id=str(row["id"]),
                    incident_id=str(row["incident_id"]),
                    event_type=row["event_type"],
                    payload=row.get("payload") or {},
                    created_at=(
                        row["created_at"].isoformat()
                        if hasattr(row["created_at"], "isoformat")
                        else str(row["created_at"])
                    ),
                )
            )
        return out

    def list_recent_events_by_type(
        self,
        event_types: list[str],
        *,
        limit: int = 100,
    ) -> list[IncidentEventRecord]:
        """Recent incident_events across all incidents filtered by event_type."""
        if not event_types:
            return []
        safe_limit = max(1, min(limit, 500))
        with self._conn() as conn:
            rows = conn.execute(
                """
                SELECT * FROM incident_events
                WHERE event_type = ANY(%s)
                ORDER BY created_at DESC
                LIMIT %s
                """,
                (event_types, safe_limit),
            ).fetchall()
        out: list[IncidentEventRecord] = []
        for row in rows:
            out.append(
                IncidentEventRecord(
                    id=str(row["id"]),
                    incident_id=str(row["incident_id"]),
                    event_type=row["event_type"],
                    payload=row.get("payload") or {},
                    created_at=(
                        row["created_at"].isoformat()
                        if hasattr(row["created_at"], "isoformat")
                        else str(row["created_at"])
                    ),
                )
            )
        return out

    def claim_next_received(self) -> IncidentRecord | None:
        """Atomically mark one received incident as investigating."""
        with self._conn() as conn:
            row = conn.execute(
                """
                SELECT id FROM incidents
                WHERE status = 'received'
                ORDER BY opened_at ASC
                LIMIT 1
                FOR UPDATE SKIP LOCKED
                """
            ).fetchone()
            if not row:
                return None
            incident_id = str(row["id"])
            conn.execute(
                """
                UPDATE incidents SET status = 'investigating', updated_at = NOW()
                WHERE id = %s
                """,
                (incident_id,),
            )
            conn.commit()
        return self.get_by_id(incident_id)

    def claim_by_id(self, incident_id: str) -> IncidentRecord | None:
        """Mark a specific received incident as investigating."""
        with self._conn() as conn:
            row = conn.execute(
                """
                SELECT id FROM incidents
                WHERE id = %s AND status = 'received'
                FOR UPDATE
                """,
                (incident_id,),
            ).fetchone()
            if not row:
                return self.get_by_id(incident_id)
            conn.execute(
                """
                UPDATE incidents SET status = 'investigating', updated_at = NOW()
                WHERE id = %s
                """,
                (incident_id,),
            )
            conn.commit()
        return self.get_by_id(incident_id)

    def update_status(
        self,
        incident_id: str,
        status: IncidentStatus,
        *,
        summary: str | None = None,
    ) -> IncidentRecord | None:
        with self._conn() as conn:
            resolved_at_sql = ", resolved_at = NOW()" if status == "resolved" else ""
            summary_sql = ", summary = %s" if summary else ""
            params: list[Any] = [status]
            if summary:
                params.append(summary)
            params.append(incident_id)
            conn.execute(
                f"""
                UPDATE incidents SET
                    status = %s,
                    updated_at = NOW()
                    {resolved_at_sql}
                    {summary_sql}
                WHERE id = %s
                """,
                tuple(params),
            )
            conn.commit()
        return self.get_by_id(incident_id)

    def save_proposal(
        self,
        *,
        incident_id: str,
        classification: RemediationClassification,
        root_cause: str,
        confidence: str,
        target_repo: str,
        target_path: str | None,
        proposed_change: str,
        rationale: str | None = None,
        briefing: dict[str, Any] | None = None,
        created_by: str | None = None,
    ) -> IncidentRemediationRecord:
        proposal_id = str(uuid.uuid4())
        briefing_payload = json.dumps(briefing) if briefing else None
        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO incident_remediations (
                    id, incident_id, classification, root_cause, confidence,
                    target_repo, target_path, proposed_change, rationale,
                    briefing_json, status, created_by
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, 'proposed', %s)
                """,
                (
                    proposal_id,
                    incident_id,
                    classification,
                    root_cause,
                    confidence,
                    target_repo,
                    target_path,
                    proposed_change,
                    rationale,
                    briefing_payload,
                    created_by,
                ),
            )
            conn.commit()
        record = self.get_proposal(proposal_id)
        assert record is not None
        return record

    def get_proposal(self, proposal_id: str) -> IncidentRemediationRecord | None:
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM incident_remediations WHERE id = %s",
                (proposal_id,),
            ).fetchone()
        return _row_to_remediation(row) if row else None

    def list_proposals(self, incident_id: str, limit: int = 20) -> list[IncidentRemediationRecord]:
        safe_limit = max(1, min(limit, 50))
        with self._conn() as conn:
            rows = conn.execute(
                """
                SELECT * FROM incident_remediations
                WHERE incident_id = %s
                ORDER BY created_at DESC
                LIMIT %s
                """,
                (incident_id, safe_limit),
            ).fetchall()
        return [_row_to_remediation(row) for row in rows]

    def set_proposal_status(
        self,
        proposal_id: str,
        status: RemediationStatus,
        *,
        pr_url: str | None = None,
    ) -> IncidentRemediationRecord | None:
        with self._conn() as conn:
            if pr_url is not None:
                conn.execute(
                    """
                    UPDATE incident_remediations SET status = %s, pr_url = %s
                    WHERE id = %s
                    """,
                    (status, pr_url, proposal_id),
                )
            else:
                conn.execute(
                    """
                    UPDATE incident_remediations SET status = %s
                    WHERE id = %s
                    """,
                    (status, proposal_id),
                )
            conn.commit()
        return self.get_proposal(proposal_id)


def _row_to_remediation(row: dict[str, Any]) -> IncidentRemediationRecord:
    created_at = row["created_at"]
    if hasattr(created_at, "isoformat"):
        created_at = created_at.isoformat()
    return IncidentRemediationRecord(
        id=str(row["id"]),
        incident_id=str(row["incident_id"]),
        classification=row["classification"],
        root_cause=row.get("root_cause") or "",
        confidence=row.get("confidence") or "medium",
        target_repo=row.get("target_repo") or "",
        target_path=row.get("target_path"),
        proposed_change=row.get("proposed_change") or "",
        rationale=row.get("rationale"),
        briefing=row.get("briefing_json") if isinstance(row.get("briefing_json"), dict) else None,
        status=row["status"],
        pr_url=row.get("pr_url"),
        created_by=row.get("created_by"),
        created_at=str(created_at),
    )
