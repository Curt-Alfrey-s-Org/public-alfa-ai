"""Runtime admin AI configuration (system prompt, hosts, actions, context).

Single-row Postgres store so the operator can change Ask ALFa behavior without
redeploy. See docs/AI_ACTIONS.md and docs/ADMIN_AI_HOST_ACTIONS.md.
"""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime
from typing import Any

import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)

CONFIG_ROW_ID = "default"

# Context section keys (all default True when missing from DB).
DEFAULT_CONTEXT_SECTIONS: dict[str, bool] = {
    "incidents": True,
    "ai_settings": True,
    "ai_actions": True,
    "cluster_health": True,
    "models_summary": True,
    "user_count": True,
    "audit_log": True,
    "pending_host_actions": True,
    "prometheus_ops": True,
    "github_ci": False,
    "missions_fleet": True,
}

_CREATE_AI_AGENT_CONFIG_TABLE = """\
CREATE TABLE IF NOT EXISTS ai_agent_config (
    id TEXT PRIMARY KEY,
    system_prompt_override TEXT,
    host_overrides JSONB NOT NULL DEFAULT '[]'::jsonb,
    disabled_actions JSONB NOT NULL DEFAULT '[]'::jsonb,
    context_sections JSONB NOT NULL DEFAULT '{}'::jsonb,
    prompt_history_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_by TEXT NOT NULL DEFAULT 'system',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
"""


class AgentConfigError(ValueError):
    """Raised when agent config validation fails."""


class AgentConfigStore:
    """Postgres persistence for the single admin AI config row."""

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_tables()
        self._seed_default()

    def _conn(self):
        from src.api.db_pool import db_connection
        return db_connection(self.database_url)

    def _ensure_tables(self) -> None:
        try:
            with self._conn() as conn:
                conn.execute(_CREATE_AI_AGENT_CONFIG_TABLE)
                conn.execute(
                    """
                    ALTER TABLE ai_agent_config
                    ADD COLUMN IF NOT EXISTS prompt_history_json JSONB NOT NULL DEFAULT '[]'::jsonb
                    """
                )
                conn.commit()
        except Exception:
            logger.exception("Failed to ensure ai_agent_config table")
            raise

    def _seed_default(self) -> None:
        from src.ops.action_packs import SENSITIVE_ACTION_DEFAULTS

        default_disabled = sorted(SENSITIVE_ACTION_DEFAULTS)
        default_disabled_json = json.dumps(default_disabled)
        try:
            with self._conn() as conn:
                conn.execute(
                    """
                    INSERT INTO ai_agent_config (id, system_prompt_override, host_overrides,
                        disabled_actions, context_sections, updated_by)
                    VALUES (%s, NULL, '[]'::jsonb, %s::jsonb, '{}'::jsonb, 'system')
                    ON CONFLICT (id) DO NOTHING
                    """,
                    (CONFIG_ROW_ID, default_disabled_json),
                )
                # Merge newly introduced sensitive keys into disabled_actions without
                # re-enabling keys the operator already turned on (only add missing).
                row = conn.execute(
                    "SELECT disabled_actions FROM ai_agent_config WHERE id = %s",
                    (CONFIG_ROW_ID,),
                ).fetchone()
                current = self._parse_json_list(row.get("disabled_actions") if row else [])
                current_set = {str(k).strip() for k in current if str(k).strip()}
                merged = sorted(current_set | set(SENSITIVE_ACTION_DEFAULTS))
                # Only write when we are adding keys (never wipe operator enables of
                # keys that were already absent from disabled_actions before this
                # code knew about them -- for brand-new keys only).
                known_before = {
                    "run_command",
                    "git_pull",
                    "docker_restart",
                    "brain_redeploy_api",
                    "cluster_start",
                    "cluster_stop",
                }
                new_keys = set(SENSITIVE_ACTION_DEFAULTS) - known_before
                to_add = sorted(k for k in new_keys if k not in current_set)
                if to_add:
                    merged = sorted(current_set | set(to_add))
                    conn.execute(
                        """
                        UPDATE ai_agent_config
                        SET disabled_actions = %s::jsonb
                        WHERE id = %s
                        """,
                        (json.dumps(merged), CONFIG_ROW_ID),
                    )
                # Legacy: empty disabled_actions -> seed run_command at minimum
                conn.execute(
                    """
                    UPDATE ai_agent_config
                    SET disabled_actions = %s::jsonb
                    WHERE id = %s
                      AND disabled_actions = '[]'::jsonb
                    """,
                    (default_disabled_json, CONFIG_ROW_ID),
                )
                conn.commit()
        except Exception:
            logger.exception("Failed to seed ai_agent_config default row")
            raise

    def _parse_json_list(self, raw: Any) -> list[Any]:
        if raw is None:
            return []
        if isinstance(raw, list):
            return raw
        if isinstance(raw, str):
            try:
                parsed = json.loads(raw)
                return parsed if isinstance(parsed, list) else []
            except json.JSONDecodeError:
                return []
        return []

    def _parse_json_dict(self, raw: Any) -> dict[str, Any]:
        if raw is None:
            return {}
        if isinstance(raw, dict):
            return raw
        if isinstance(raw, str):
            try:
                parsed = json.loads(raw)
                return parsed if isinstance(parsed, dict) else {}
            except json.JSONDecodeError:
                return {}
        return {}

    def _row_to_config(self, row: dict[str, Any]) -> dict[str, Any]:
        sections = dict(DEFAULT_CONTEXT_SECTIONS)
        stored_sections = self._parse_json_dict(row.get("context_sections"))
        for key, val in stored_sections.items():
            if key in DEFAULT_CONTEXT_SECTIONS:
                sections[key] = bool(val)

        host_overrides = self._parse_json_list(row.get("host_overrides"))
        disabled_actions = [
            str(k).strip()
            for k in self._parse_json_list(row.get("disabled_actions"))
            if str(k).strip()
        ]

        updated_at = row.get("updated_at")
        history = self._parse_json_list(row.get("prompt_history_json"))
        return {
            "system_prompt_override": row.get("system_prompt_override"),
            "host_overrides": host_overrides,
            "disabled_actions": disabled_actions,
            "context_sections": sections,
            "prompt_history": history[-20:],
            "updated_by": row.get("updated_by") or "system",
            "updated_at": updated_at.isoformat() if hasattr(updated_at, "isoformat") else str(updated_at),
        }

    def get(self) -> dict[str, Any]:
        with self._conn() as conn:
            row = conn.execute(
                "SELECT * FROM ai_agent_config WHERE id = %s",
                (CONFIG_ROW_ID,),
            ).fetchone()
        if row is None:
            return {
                "system_prompt_override": None,
                "host_overrides": [],
                "disabled_actions": [],
                "context_sections": dict(DEFAULT_CONTEXT_SECTIONS),
                "prompt_history": [],
                "updated_by": "system",
                "updated_at": datetime.now(tz=UTC).isoformat(),
            }
        return self._row_to_config(row)

    def update_prompt(self, text: str | None, *, updated_by: str) -> dict[str, Any]:
        override = (text or "").strip() or None
        current = self.get()
        history: list[dict[str, Any]] = list(current.get("prompt_history") or [])
        previous = current.get("system_prompt_override")
        if previous != override:
            history.append(
                {
                    "text": previous,
                    "updated_by": current.get("updated_by") or "system",
                    "updated_at": current.get("updated_at"),
                }
            )
            history = history[-20:]
        payload = json.dumps(history)
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE ai_agent_config
                SET system_prompt_override = %s,
                    prompt_history_json = %s::jsonb,
                    updated_by = %s,
                    updated_at = %s
                WHERE id = %s
                """,
                (override, payload, updated_by, datetime.now(tz=UTC), CONFIG_ROW_ID),
            )
            conn.commit()
            row = conn.execute(
                "SELECT * FROM ai_agent_config WHERE id = %s",
                (CONFIG_ROW_ID,),
            ).fetchone()
        assert row is not None
        return self._row_to_config(row)

    def update_hosts(self, hosts: list[dict[str, Any]], *, updated_by: str) -> dict[str, Any]:
        normalized: list[dict[str, Any]] = []
        seen_keys: set[str] = set()
        for entry in hosts:
            if not isinstance(entry, dict):
                continue
            key = str(entry.get("key") or "").strip()
            if not key or key in seen_keys:
                continue
            seen_keys.add(key)
            normalized.append(dict(entry))

        payload = json.dumps(normalized)
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE ai_agent_config
                SET host_overrides = %s::jsonb, updated_by = %s, updated_at = %s
                WHERE id = %s
                """,
                (payload, updated_by, datetime.now(tz=UTC), CONFIG_ROW_ID),
            )
            conn.commit()
            row = conn.execute(
                "SELECT * FROM ai_agent_config WHERE id = %s",
                (CONFIG_ROW_ID,),
            ).fetchone()
        assert row is not None
        return self._row_to_config(row)

    def update_disabled_actions(self, keys: list[str], *, updated_by: str) -> dict[str, Any]:
        disabled = sorted({str(k).strip() for k in keys if str(k).strip()})
        payload = json.dumps(disabled)
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE ai_agent_config
                SET disabled_actions = %s::jsonb, updated_by = %s, updated_at = %s
                WHERE id = %s
                """,
                (payload, updated_by, datetime.now(tz=UTC), CONFIG_ROW_ID),
            )
            conn.commit()
            row = conn.execute(
                "SELECT * FROM ai_agent_config WHERE id = %s",
                (CONFIG_ROW_ID,),
            ).fetchone()
        assert row is not None
        return self._row_to_config(row)

    def update_context_sections(
        self,
        sections: dict[str, bool],
        *,
        updated_by: str,
    ) -> dict[str, Any]:
        current = self.get()["context_sections"]
        merged = dict(current)
        for key in DEFAULT_CONTEXT_SECTIONS:
            if key in sections:
                merged[key] = bool(sections[key])
        payload = json.dumps(merged)
        with self._conn() as conn:
            conn.execute(
                """
                UPDATE ai_agent_config
                SET context_sections = %s::jsonb, updated_by = %s, updated_at = %s
                WHERE id = %s
                """,
                (payload, updated_by, datetime.now(tz=UTC), CONFIG_ROW_ID),
            )
            conn.commit()
            row = conn.execute(
                "SELECT * FROM ai_agent_config WHERE id = %s",
                (CONFIG_ROW_ID,),
            ).fetchone()
        assert row is not None
        return self._row_to_config(row)
