"""Runtime AI/chat settings editable by AI and operator (mostly alert/notification domain,
plus a few operator-only chat UX toggles like chat_thinking_label).

Values live in Postgres (not env) so the AI and the admin can change them without a
redeploy. AI writes are rejected for keys where editable_by_ai is false. See docs/AI_ACTIONS.md.
"""

from __future__ import annotations

import logging
import os
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from email.errors import HeaderParseError
from email.headerregistry import Address
from email.utils import parseaddr
from typing import Any

import psycopg
from psycopg.rows import dict_row

logger = logging.getLogger(__name__)

# Ordered severity ladder used for threshold comparisons.
SEVERITY_ORDER: tuple[str, ...] = ("low", "medium", "high", "critical")


@dataclass(slots=True)
class AiSettingRecord:
    key: str
    value: str
    description: str
    editable_by_ai: bool
    updated_by: str
    updated_at: str


def _default_notify_email() -> str:
    return (os.getenv("ALFA_AI_INCIDENT_NOTIFY_EMAIL") or "").strip()


# key -> (default_value, description, editable_by_ai)
_DEFAULTS: dict[str, tuple[str, str, bool]] = {
    "ai_triage_enabled": ("true", "Master switch for programmatic alert notify routing.", False),
    "ai_can_adjust_settings": ("false", "Master switch for program self-tuning of settings (default off).", False),
    "notify_email": ("", "Where direct AI alert emails are sent (defaults to incident notify email).", False),
    "notify_min_severity": ("high", "Minimum assessed severity to email you (low<medium<high<critical).", True),
    "notify_quiet_hours": ("", "Local quiet window e.g. 22:00-07:00; alerts held during window.", True),
    "notify_dedup_minutes": ("30", "Suppress repeat notifications for the same alert within N minutes.", True),
    "auto_fix_allowlist": (
        "",
        "Comma-separated alertnames allowed for L3 auto_fix when ALFA_AI_INCIDENT_AUTO_FIX=true (empty = none).",
        False,
    ),
    "chat_thinking_label": (
        "I'm Thinking.....|I'm Thinnnking....|I'mmmm Thiiinnnnkiinng",
        "Text shown in chat/guest chat while ALFa is 'thinking' (replaces raw <think> "
        "reasoning). Pipe-separated phrases cycle while thinking. Leave blank to show nothing.",
        False,
    ),
    "ask_alfa_inspect_autorun": (
        "true",
        "Allow Ask ALFa to auto-run read-only inspect catalog actions inside a turn (L1 observe).",
        False,
    ),
    "ha_solar_dump_enabled": (
        "true",
        "Arm deterministic solar dump-load ticker (Home Assistant REST on apps; no 7B/27B).",
        False,
    ),
    "ha_solar_dump_auto_actuate": (
        "false",
        "Unused for dump on/off (Home Assistant automations own switches).",
        False,
    ),
    "ha_switch_allowlist": (
        "switch.sim_ac_plug_1,switch.sim_ac_plug_2,switch.sim_ac_plug_3,"
        "switch.sim_ac_plug_4,switch.sim_ac_plug_5,switch.sim_ac_plug_6",
        "Comma-separated switch/light entity ids Ask ALFa ha_switch_* may toggle "
        "(empty = never). Dump on/off is Home Assistant automations.",
        False,
    ),
    "ha_switch_watts": (
        "",
        "Optional entity_id=watts overlay when ha_load_entity is a plant clamp "
        "(not sensor.sim_dump_load_power). Dump plug watts come from HA live "
        "power sensors, not this map.",
        False,
    ),
    "ha_never_auto": (
        "",
        "Comma-separated entity ids never toggled by ha_switch_* (subtracted from allowlist).",
        False,
    ),
    "ha_solar_entity": (
        "sensor.solar_controller_solar",
        "Instantaneous PV watts sensor for dump-load surplus (Victron MQTT entity_id). "
        "Stale DB values sensor.solar_controller_solar_power remap at runtime.",
        False,
    ),
    "ha_load_entity": (
        "sensor.sim_dump_load_power",
        "Plant AC load watts for dump-load surplus. Default sim aggregate (0 plant AC). "
        "Do not use sensor.em16_a3_power while A3 is Sungold AC-in.",
        False,
    ),
    "ha_soc_entity": (
        "sensor.battery_1_state_of_charge",
        "Battery state-of-charge percent sensor (Victron MQTT). "
        "Stale DB values sensor.battery_1_soc remap at runtime. Display only while ha_soc_unsynced=true.",
        False,
    ),
    "ha_shunt_voltage_entity": (
        "sensor.battery_1_voltage",
        "SmartShunt voltage for dump-load thinking (not a SoC substitute).",
        False,
    ),
    "ha_shunt_current_entity": (
        "sensor.battery_1_current",
        "SmartShunt current for dump-load thinking (+charge / -discharge).",
        False,
    ),
    "ha_soc_unsynced": (
        "true",
        "When true, skip ha_min_soc_percent (SmartShunt SoC unsynchronised).",
        False,
    ),
    "ha_charge_state_entity": (
        "sensor.solar_controller_charge_state",
        "MPPT charge stage sensor (float, absorption, ...). "
        "Stale DB values sensor.solar_controller_battery_state remap at runtime.",
        False,
    ),
    "ha_charge_states_ok": (
        "absorption,float",
        "Allowed MPPT stages for dump-on briefing (Victron battery-first; not bulk).",
        False,
    ),
    "ha_weather_entity": (
        "weather.417373300314",
        "Outdoor weather entity for observe-only context (Ecobee; not climate thermostat). "
        "Empty skips weather.get_forecasts in dump/Ask ALFa.",
        False,
    ),
    "ha_min_soc_percent": (
        "95",
        "SoC floor for dump-on when ha_soc_unsynced=false (leave 95%+ after solar stops).",
        False,
    ),
    "ha_min_solar_watts": (
        "50",
        "PV below this is solar-gone (weather or end of day). HA dump_min_solar_w helper wins when present.",
        False,
    ),
    "ha_min_surplus_watts": (
        "200",
        "Audit-only leftover PV band. Not the dump ON trigger (float throttles PV watts).",
        False,
    ),
    "ha_off_surplus_watts": (
        "50",
        "Audit-only leftover PV band. Dump OFF is solar-gone / re-bulk / left-float.",
        False,
    ),
    "ha_interval_seconds": (
        "900",
        "Solar dump-load ticker interval seconds (60-3600).",
        False,
    ),
    "ha_max_concurrent_on": (
        "6",
        "Maximum allowlisted switches left on by dump loads.",
        False,
    ),
    "ha_min_on_seconds": (
        "600",
        "Minimum dwell after turn_on before turn_off.",
        False,
    ),
    "ha_min_off_seconds": (
        "300",
        "Minimum dwell after turn_off before turn_on.",
        False,
    ),
}


_BOOL_KEYS: frozenset[str] = frozenset(
    key for key, (default, _, _) in _DEFAULTS.items() if default in ("true", "false")
)
_BOOL_TRUTHY: frozenset[str] = frozenset({"true", "on", "1", "yes"})
_BOOL_FALSY: frozenset[str] = frozenset({"false", "off", "0", "no"})
_SEVERITY_VALUES: frozenset[str] = frozenset(SEVERITY_ORDER)
_QUIET_HOURS_RE = re.compile(r"^(\d{2}):(\d{2})-(\d{2}):(\d{2})$")
_HA_ENTITY_ID_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}\.[a-z0-9_]{1,255}$")
_HA_CHARGE_TOKEN_RE = re.compile(r"^[a-z_]+$")
_HA_ENTITY_LIST_KEYS = frozenset({"ha_switch_allowlist", "ha_never_auto"})
_HA_SINGLE_ENTITY_KEYS = frozenset(
    {
        "ha_solar_entity",
        "ha_load_entity",
        "ha_soc_entity",
        "ha_shunt_voltage_entity",
        "ha_shunt_current_entity",
        "ha_charge_state_entity",
    }
)
_HA_OPTIONAL_SINGLE_ENTITY_KEYS = frozenset({"ha_weather_entity"})
NOTIFY_DEDUP_MINUTES_MAX = 10080  # 7 days; used by decide_notification dedup window

# Keys whose defaults are true/false strings (Turn on|off fast path).
BOOL_SETTING_KEYS: frozenset[str] = _BOOL_KEYS


def normalize_setting_input(key: str, value: str) -> str:
    """Normalize operator/LLM input before validate_setting_value (e.g. trailing sentence period)."""
    if key == "notify_email" and value.endswith(".") and value.count("@") == 1:
        return value[:-1]
    return value


def validate_setting_value(key: str, value: str) -> str:
    """Return normalized value or raise AiSettingError with an operator-readable message."""
    if key not in _DEFAULTS:
        raise AiSettingError(f"Unknown setting: {key}")

    raw = value if value is not None else ""
    if "\n" in raw or "\r" in raw:
        raise AiSettingError(f"'{key}' value must not contain newlines")

    if key == "notify_email":
        return _validate_notify_email(raw)
    if key == "notify_min_severity":
        return _validate_notify_min_severity(raw)
    if key == "notify_quiet_hours":
        return _validate_notify_quiet_hours(raw)
    if key == "notify_dedup_minutes":
        return _validate_notify_dedup_minutes(raw)
    if key == "auto_fix_allowlist":
        return _validate_auto_fix_allowlist(raw)
    if key in _BOOL_KEYS:
        return _validate_bool_setting(key, raw)
    if key in _HA_ENTITY_LIST_KEYS:
        return _validate_ha_entity_list(key, raw)
    if key in _HA_SINGLE_ENTITY_KEYS:
        return _validate_ha_single_entity(key, raw)
    if key in _HA_OPTIONAL_SINGLE_ENTITY_KEYS:
        return _validate_ha_optional_single_entity(key, raw)
    if key == "ha_charge_states_ok":
        return _validate_ha_charge_states_ok(raw)
    if key == "ha_switch_watts":
        return _validate_ha_switch_watts(raw)
    if key == "ha_min_soc_percent":
        return _validate_ha_int_range(key, raw, 0, 100)
    if key in ("ha_min_surplus_watts", "ha_off_surplus_watts", "ha_min_solar_watts"):
        return _validate_ha_int_range(key, raw, -100000, 100000)
    if key == "ha_interval_seconds":
        return _validate_ha_int_range(key, raw, 60, 3600)
    if key == "ha_max_concurrent_on":
        return _validate_ha_int_range(key, raw, 1, 16)
    if key in ("ha_min_on_seconds", "ha_min_off_seconds"):
        return _validate_ha_int_range(key, raw, 0, 86400)
    return raw


def _validate_notify_email(value: str) -> str:
    if not value:
        return ""
    if any(ch.isspace() for ch in value):
        raise AiSettingError(
            "notify_email must be empty or a single email address with no whitespace"
        )
    if value.count("@") != 1:
        raise AiSettingError("notify_email must be a single valid email address")
    local, domain = value.split("@", 1)
    if not local or not domain or "." not in domain:
        raise AiSettingError("notify_email must be a single valid email address")
    # https://docs.python.org/3/library/email.utils.html
    _display, addr = parseaddr(value)
    if not addr or addr != value:
        raise AiSettingError("notify_email must be a single valid email address")
    try:
        # Address may raise ValueError, TypeError, or HeaderParseError per:
        # https://docs.python.org/3/library/email.headerregistry.html
        # https://docs.python.org/3/library/email.errors.html
        Address(addr_spec=addr)
    except (ValueError, TypeError, HeaderParseError) as exc:
        raise AiSettingError("notify_email must be a single valid email address") from exc
    return value


def _validate_notify_min_severity(value: str) -> str:
    normalized = value.strip().lower()
    if normalized not in _SEVERITY_VALUES:
        allowed = ", ".join(SEVERITY_ORDER)
        raise AiSettingError(
            f"notify_min_severity must be one of: {allowed} (got {value!r})"
        )
    return normalized


def _validate_notify_quiet_hours(value: str) -> str:
    if not value.strip():
        return ""
    match = _QUIET_HOURS_RE.match(value.strip())
    if not match:
        raise AiSettingError(
            "notify_quiet_hours must be empty or HH:MM-HH:MM in 24-hour format (e.g. 22:00-07:00)"
        )
    for hour_s, minute_s in (
        (match.group(1), match.group(2)),
        (match.group(3), match.group(4)),
    ):
        hour = int(hour_s)
        minute = int(minute_s)
        if hour < 0 or hour > 23 or minute < 0 or minute > 59:
            raise AiSettingError(
                "notify_quiet_hours must use valid hour (00-23) and minute (00-59) ranges"
            )
    return value.strip()


def _validate_notify_dedup_minutes(value: str) -> str:
    text = value.strip()
    if not text:
        raise AiSettingError("notify_dedup_minutes must be a non-negative integer")
    # str.isdigit() is True for superscripts and other non-decimal digits that int()
    # rejects, and int() refuses strings past the interpreter digit limit.
    # https://docs.python.org/3/library/stdtypes.html#str.isdigit
    if not (text.isascii() and text.isdigit()):
        raise AiSettingError(
            f"notify_dedup_minutes must be a plain non-negative integer (got {value!r})"
        )
    try:
        parsed = int(text)
    except ValueError as exc:
        raise AiSettingError(
            f"notify_dedup_minutes must be a plain non-negative integer (got {value!r})"
        ) from exc
    if parsed > NOTIFY_DEDUP_MINUTES_MAX:
        raise AiSettingError(
            f"notify_dedup_minutes must be at most {NOTIFY_DEDUP_MINUTES_MAX} minutes (7 days)"
        )
    return str(parsed)


def _validate_auto_fix_allowlist(value: str) -> str:
    if not value.strip():
        return ""
    tokens: list[str] = []
    for part in value.split(","):
        token = part.strip()
        if not token:
            raise AiSettingError(
                "auto_fix_allowlist must be empty or comma-separated alertname tokens"
            )
        if any(ch.isspace() for ch in token):
            raise AiSettingError(
                "auto_fix_allowlist tokens must not contain internal whitespace"
            )
        tokens.append(token)
    return ",".join(tokens)


def _validate_ha_entity_id(token: str) -> str:
    normalized = token.strip()
    if not _HA_ENTITY_ID_RE.match(normalized):
        raise AiSettingError(
            f"Invalid entity_id {token!r} (expected domain.object_id per HA docs)"
        )
    return normalized


def _validate_ha_entity_list(key: str, value: str) -> str:
    if not value.strip():
        return ""
    tokens: list[str] = []
    for part in value.split(","):
        token = part.strip()
        if not token:
            raise AiSettingError(f"'{key}' must not contain empty comma segments")
        tokens.append(_validate_ha_entity_id(token))
    return ",".join(tokens)


def _validate_ha_single_entity(key: str, value: str) -> str:
    if not value.strip():
        raise AiSettingError(f"'{key}' must be a non-empty entity_id")
    return _validate_ha_entity_id(value)


def _validate_ha_optional_single_entity(key: str, value: str) -> str:
    if not value.strip():
        return ""
    return _validate_ha_entity_id(value)


def _validate_ha_switch_watts(value: str) -> str:
    if not value.strip():
        return ""
    pairs: list[str] = []
    for part in value.split(","):
        token = part.strip()
        if not token:
            raise AiSettingError("ha_switch_watts must not contain empty comma segments")
        if "=" not in token:
            raise AiSettingError(
                "ha_switch_watts pairs must be entity_id=watts (comma-separated)"
            )
        eid_raw, watts_raw = token.split("=", 1)
        eid = _validate_ha_entity_id(eid_raw)
        watts = _validate_ha_int_range("ha_switch_watts", watts_raw.strip(), 0, 100000)
        pairs.append(f"{eid}={watts}")
    return ",".join(pairs)


def _validate_ha_charge_states_ok(value: str) -> str:
    if not value.strip():
        raise AiSettingError("ha_charge_states_ok must list at least one token")
    tokens: list[str] = []
    for part in value.split(","):
        token = part.strip().lower()
        if not token:
            raise AiSettingError("ha_charge_states_ok must not contain empty segments")
        if not _HA_CHARGE_TOKEN_RE.match(token):
            raise AiSettingError(
                f"ha_charge_states_ok tokens must be lowercase [a-z_]+ (got {token!r})"
            )
        tokens.append(token)
    return ",".join(tokens)


def _validate_ha_int_range(key: str, value: str, low: int, high: int) -> str:
    text = value.strip()
    if not text or not (text.lstrip("-").isdigit() if text.startswith("-") else text.isdigit()):
        raise AiSettingError(f"'{key}' must be an integer between {low} and {high}")
    try:
        parsed = int(text)
    except ValueError as exc:
        raise AiSettingError(f"'{key}' must be an integer between {low} and {high}") from exc
    if parsed < low or parsed > high:
        raise AiSettingError(f"'{key}' must be between {low} and {high} (got {parsed})")
    return str(parsed)


def _validate_bool_setting(key: str, value: str) -> str:
    normalized = value.strip().lower()
    if normalized in _BOOL_TRUTHY:
        return "true"
    if normalized in _BOOL_FALSY:
        return "false"
    raise AiSettingError(
        f"'{key}' must be true or false (also accepts on/off, 1/0, yes/no; got {value!r})"
    )


_CREATE_AI_SETTINGS_TABLE = """\
CREATE TABLE IF NOT EXISTS ai_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    editable_by_ai BOOLEAN NOT NULL DEFAULT FALSE,
    updated_by TEXT NOT NULL DEFAULT 'system',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
"""


class AiSettingError(ValueError):
    """Raised when a setting write is rejected (unknown key or AI not allowed)."""


# Kill-switch / policy keys: Ask ALFa and chat cannot apply immediately; require Approve.
POLICY_SETTING_KEYS: frozenset[str] = frozenset(
    {
        "ai_triage_enabled",
        "ai_can_adjust_settings",
        "notify_email",
        "auto_fix_allowlist",
        "ask_alfa_inspect_autorun",
        "ha_solar_dump_enabled",
        "ha_solar_dump_auto_actuate",
        "ha_switch_allowlist",
    }
)

POLICY_SETTING_REQUIRES_APPROVE_REASON = (
    "This is a policy / kill-switch key and cannot be applied by chat without operator Approve."
)


def setting_description(key: str) -> str:
    """Human-readable description for a known setting key (from seeded defaults)."""
    entry = _DEFAULTS.get(key)
    return entry[1] if entry else ""


def program_auto_tune_enabled() -> bool:
    """Env gate for bounded program tuning (default off per NIST/SRE oversight)."""
    raw = (os.getenv("ALFA_AI_PROGRAM_AUTO_TUNE") or "0").strip().lower()
    return raw in ("1", "true", "yes", "on")


def is_policy_setting(key: str) -> bool:
    return key in POLICY_SETTING_KEYS


def inspect_autorun_enabled(settings_rows_or_store: Any) -> bool:
    """True when Ask ALFa may auto-run read-only inspect steps (default True)."""
    if hasattr(settings_rows_or_store, "get_bool"):
        return settings_rows_or_store.get_bool("ask_alfa_inspect_autorun", True)
    if isinstance(settings_rows_or_store, dict):
        raw = settings_rows_or_store.get("ask_alfa_inspect_autorun", "true")
        return str(raw).strip().lower() in _BOOL_TRUTHY
    for row in settings_rows_or_store:
        key = row.get("key") if isinstance(row, dict) else getattr(row, "key", None)
        if key == "ask_alfa_inspect_autorun":
            val = row.get("value") if isinstance(row, dict) else getattr(row, "value", "true")
            return str(val).strip().lower() in _BOOL_TRUTHY
    return True


def _row_to_setting(row: dict[str, Any]) -> AiSettingRecord:
    updated_at = row["updated_at"]
    return AiSettingRecord(
        key=row["key"],
        value=row.get("value") or "",
        description=row.get("description") or "",
        editable_by_ai=bool(row.get("editable_by_ai")),
        updated_by=row.get("updated_by") or "system",
        updated_at=updated_at.isoformat() if hasattr(updated_at, "isoformat") else str(updated_at),
    )


class AiSettingStore:
    """Postgres persistence for runtime AI settings with a seeded default set."""

    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_tables()
        self._seed_defaults()

    def _ensure_tables(self) -> None:
        try:
            from src.api.db_pool import db_connection

            with db_connection(self.database_url) as conn:
                conn.execute(_CREATE_AI_SETTINGS_TABLE)
                conn.commit()
        except Exception:
            logger.exception("Failed to ensure ai_settings table")
            raise

    def _seed_defaults(self) -> None:
        try:
            from src.api.db_pool import db_connection

            with db_connection(self.database_url) as conn:
                for key, (value, description, editable) in _DEFAULTS.items():
                    seed_value = _default_notify_email() if key == "notify_email" and not value else value
                    conn.execute(
                        """
                        INSERT INTO ai_settings (key, value, description, editable_by_ai, updated_by)
                        VALUES (%s, %s, %s, %s, 'system')
                        ON CONFLICT (key) DO UPDATE
                            SET description = EXCLUDED.description,
                                editable_by_ai = EXCLUDED.editable_by_ai
                        """,
                        (key, seed_value, description, editable),
                    )
                conn.commit()
        except Exception:
            logger.exception("Failed to seed ai_settings defaults")
            raise

    def all(self) -> list[AiSettingRecord]:
        from src.api.db_pool import db_connection

        with db_connection(self.database_url) as conn:
            rows = conn.execute("SELECT * FROM ai_settings ORDER BY key ASC").fetchall()
        return [_row_to_setting(row) for row in rows]

    def get(self, key: str, default: str = "") -> str:
        from src.api.db_pool import db_connection

        with db_connection(self.database_url) as conn:
            row = conn.execute("SELECT value FROM ai_settings WHERE key = %s", (key,)).fetchone()
        if row is None:
            return default
        return row.get("value") or default

    def get_bool(self, key: str, default: bool = False) -> bool:
        raw = self.get(key, "true" if default else "false").strip().lower()
        return raw in ("1", "true", "yes", "on")

    def get_int(self, key: str, default: int) -> int:
        try:
            return int((self.get(key, str(default)) or str(default)).strip())
        except ValueError:
            return default

    def set(self, key: str, value: str, *, updated_by: str, by_ai: bool = False) -> AiSettingRecord:
        """Persist a setting. Rejects unknown keys and AI writes to user-only keys.

        Returns the updated record. Callers log the change to the AI Actions feed.
        """
        if key not in _DEFAULTS:
            raise AiSettingError(f"Unknown setting: {key}")
        from src.api.db_pool import db_connection

        with db_connection(self.database_url) as conn:
            existing = conn.execute(
                "SELECT * FROM ai_settings WHERE key = %s", (key,)
            ).fetchone()
            if existing is None:
                raise AiSettingError(f"Unknown setting: {key}")
            if by_ai and not bool(existing.get("editable_by_ai")):
                raise AiSettingError(f"AI is not allowed to change '{key}'")
            normalized = validate_setting_value(key, value)
            conn.execute(
                """
                UPDATE ai_settings
                SET value = %s, updated_by = %s, updated_at = %s
                WHERE key = %s
                """,
                (normalized, updated_by, datetime.now(tz=UTC), key),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM ai_settings WHERE key = %s", (key,)).fetchone()
        assert row is not None
        return _row_to_setting(row)
