"""Execute Home Assistant catalog actions inside the brain API (no SSH)."""

from __future__ import annotations

import json
import logging
import os
from typing import Any

from src.ops.exec_result import ExecResult
from src.ops.home_assistant_client import (
    DEFAULT_WEATHER_ENTITY,
    HomeAssistantError,
    compact_forecast_entries,
    forecast_entries_from_response,
    ha_call_service,
    ha_call_helper_service,
    ha_get_forecasts,
    ha_get_state,
    ha_get_states,
    home_assistant_enabled,
    home_assistant_token_present,
    validate_entity_id,
    validate_forecast_type,
    validate_weather_entity_id,
)
from src.ops.solar_dump import (
    DUMP_HA_NUMBER_HELPERS,
    DUMP_HA_SELECT_HELPERS,
    DUMP_HA_SELECT_OPTIONS,
    _dump_sensor_entities,
    _settings_dict,
    load_ha_never_auto,
    load_ha_switch_allowlist,
    run_dump_tick,
)

logger = logging.getLogger(__name__)

_HA_DUMP_TICK_ALIASES = frozenset({"ha_dump_tick", "ha_soak_tick"})

INTERNAL_HA_ACTIONS = frozenset(
    {
        "ha_get_states",
        "ha_get_state",
        "ha_get_forecasts",
        "ha_switch_on",
        "ha_switch_off",
        "ha_dump_tick",
        "ha_soak_tick",
        "ha_set_number",
        "ha_select_option",
    }
)


def is_internal_ha_action(action_key: str) -> bool:
    return action_key in INTERNAL_HA_ACTIONS


def _ha_not_ready_result(action_key: str) -> ExecResult:
    if not home_assistant_enabled():
        msg = "Home Assistant disabled (ALFA_AI_HOME_ASSISTANT_ENABLED=0)"
    elif not home_assistant_token_present():
        msg = "Home Assistant token file missing or empty"
    else:
        msg = "Home Assistant not ready"
    return ExecResult(
        ok=False,
        command_run=action_key,
        stdout="",
        stderr=msg,
        exit_code=127,
    )


def _format_states_stdout(rows: list[dict[str, Any]]) -> str:
    compact = []
    for row in rows:
        eid = row.get("entity_id")
        state = row.get("state")
        compact.append({"entity_id": eid, "state": state})
    return json.dumps(compact, indent=2, ensure_ascii=True)


async def execute_internal_ha_action(
    action_key: str, params: dict[str, Any] | None
) -> ExecResult:
    if not home_assistant_enabled() or not home_assistant_token_present():
        return _ha_not_ready_result(action_key)

    normalized = dict(params or {})
    store = None
    db_url = (os.getenv("DATABASE_URL") or "").strip()
    if db_url:
        try:
            from src.api.models.ai_setting import AiSettingStore

            store = AiSettingStore(db_url)
        except Exception:
            logger.debug("ha_executor: settings store unavailable", exc_info=True)

    settings = _settings_dict(store)

    try:
        if action_key == "ha_get_states":
            ids = _dump_sensor_entities(settings)
            seen = set(ids)
            for eid in sorted(load_ha_switch_allowlist(store)):
                if eid not in seen:
                    seen.add(eid)
                    ids.append(eid)
            for eid in sorted(DUMP_HA_NUMBER_HELPERS | DUMP_HA_SELECT_HELPERS):
                if eid not in seen:
                    seen.add(eid)
                    ids.append(eid)
            rows = await ha_get_states(ids, require_all=False)
            return ExecResult(
                ok=True,
                command_run="GET /api/states (dump sensors + allowlist)",
                stdout=_format_states_stdout(rows),
                stderr="",
                exit_code=0,
            )

        if action_key == "ha_get_state":
            entity_id = validate_entity_id(str(normalized.get("entity_id") or ""))
            row = await ha_get_state(entity_id)
            return ExecResult(
                ok=True,
                command_run=f"GET /api/states/{entity_id}",
                stdout=_format_states_stdout([row]),
                stderr="",
                exit_code=0,
            )

        if action_key == "ha_get_forecasts":
            entity_id = validate_weather_entity_id(
                str(normalized.get("entity_id") or DEFAULT_WEATHER_ENTITY)
            )
            forecast_type = validate_forecast_type(
                str(normalized.get("type") or "daily")
            )
            payload = await ha_get_forecasts(entity_id, forecast_type)
            entries = compact_forecast_entries(
                forecast_entries_from_response(payload, entity_id), limit=8
            )
            stdout = json.dumps(
                {
                    "entity_id": entity_id,
                    "type": forecast_type,
                    "forecast": entries,
                },
                indent=2,
                ensure_ascii=True,
                default=str,
            )
            return ExecResult(
                ok=True,
                command_run=(
                    f"POST /api/services/weather/get_forecasts?return_response "
                    f"entity={entity_id} type={forecast_type}"
                ),
                stdout=stdout,
                stderr="",
                exit_code=0,
            )

        if action_key in ("ha_switch_on", "ha_switch_off"):
            raw_entity_id = str(normalized.get("entity_id") or "").strip()
            if not raw_entity_id:
                return ExecResult(
                    ok=False,
                    command_run=action_key,
                    stdout="",
                    stderr=f"{action_key} requires params.entity_id",
                    exit_code=2,
                )
            entity_id = validate_entity_id(raw_entity_id)
            allowlist = load_ha_switch_allowlist(store)
            service = "turn_on" if action_key == "ha_switch_on" else "turn_off"
            if not allowlist or entity_id not in allowlist:
                return ExecResult(
                    ok=False,
                    command_run=f"POST /api/services/switch/{service} entity={entity_id}",
                    stdout="",
                    stderr=f"entity_id {entity_id!r} not in ha_switch_allowlist",
                    exit_code=2,
                )
            if entity_id in load_ha_never_auto(store):
                return ExecResult(
                    ok=False,
                    command_run=f"POST entity={entity_id}",
                    stdout="",
                    stderr=f"entity_id {entity_id!r} is in ha_never_auto",
                    exit_code=2,
                )
            domain = entity_id.split(".", 1)[0]
            await ha_call_service(domain, service, entity_id)
            cmd = f"POST /api/services/{domain}/{service} entity={entity_id}"
            return ExecResult(
                ok=True,
                command_run=cmd,
                stdout=f"{entity_id} -> {service}",
                stderr="",
                exit_code=0,
            )

        if action_key == "ha_set_number":
            entity_id = validate_entity_id(str(normalized.get("entity_id") or ""))
            if entity_id not in DUMP_HA_NUMBER_HELPERS:
                return ExecResult(
                    ok=False,
                    command_run=action_key,
                    stdout="",
                    stderr=f"entity_id {entity_id!r} is not an allowlisted dump number helper",
                    exit_code=2,
                )
            value = float(normalized["value"])
            await ha_call_helper_service(
                "input_number", "set_value", entity_id, {"value": value}
            )
            cmd = (
                f"POST /api/services/input_number/set_value entity={entity_id} "
                f"value={value}"
            )
            return ExecResult(
                ok=True,
                command_run=cmd,
                stdout=f"{entity_id} -> {value}",
                stderr="",
                exit_code=0,
            )

        if action_key == "ha_select_option":
            entity_id = validate_entity_id(str(normalized.get("entity_id") or ""))
            option = str(normalized.get("option") or "").strip()
            if entity_id not in DUMP_HA_SELECT_HELPERS:
                return ExecResult(
                    ok=False,
                    command_run=action_key,
                    stdout="",
                    stderr=f"entity_id {entity_id!r} is not an allowlisted dump inverter select",
                    exit_code=2,
                )
            if option not in DUMP_HA_SELECT_OPTIONS:
                return ExecResult(
                    ok=False,
                    command_run=action_key,
                    stdout="",
                    stderr="option must be T2, KU, or Sungold",
                    exit_code=2,
                )
            await ha_call_helper_service(
                "input_select", "select_option", entity_id, {"option": option}
            )
            cmd = (
                f"POST /api/services/input_select/select_option entity={entity_id} "
                f"option={option}"
            )
            return ExecResult(
                ok=True,
                command_run=cmd,
                stdout=f"{entity_id} -> {option}",
                stderr="",
                exit_code=0,
            )

        if action_key in _HA_DUMP_TICK_ALIASES:
            tick = await run_dump_tick(actuate=False)
            stdout = json.dumps(tick, indent=2, ensure_ascii=True, default=str)
            ok = bool(tick.get("ok", True))
            return ExecResult(
                ok=ok,
                command_run="solar_dump_tick",
                stdout=stdout,
                stderr=str(tick.get("error") or ""),
                exit_code=0 if ok else 1,
            )

    except HomeAssistantError as exc:
        return ExecResult(
            ok=False,
            command_run=action_key,
            stdout="",
            stderr=str(exc),
            exit_code=1 if exc.status_code not in (401, 404) else exc.status_code,
        )
    except ValueError as exc:
        return ExecResult(
            ok=False,
            command_run=action_key,
            stdout="",
            stderr=str(exc),
            exit_code=2,
        )

    return ExecResult(
        ok=False,
        command_run=action_key,
        stdout="",
        stderr=f"not an internal HA action: {action_key}",
        exit_code=2,
    )
