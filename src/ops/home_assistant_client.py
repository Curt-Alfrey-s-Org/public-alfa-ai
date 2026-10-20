"""Home Assistant REST client for brain API (httpx, Bearer token).

Official API: https://developers.home-assistant.io/docs/api/rest/
"""

from __future__ import annotations

import logging
import os
import re
from typing import Any

import httpx

logger = logging.getLogger(__name__)

ENTITY_ID_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}\.[a-z0-9_]{1,255}$")
_CONTROL_DOMAINS = frozenset({"switch", "light"})
_HA_TIMEOUT_SEC = 15.0
FORECAST_TYPES = frozenset({"daily", "hourly", "twice_daily"})
DEFAULT_WEATHER_ENTITY = "weather.417373300314"


class HomeAssistantError(Exception):
    """Structured HA REST error (never includes the token)."""

    def __init__(self, message: str, *, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


def home_assistant_enabled() -> bool:
    raw = (os.getenv("ALFA_AI_HOME_ASSISTANT_ENABLED") or "0").strip().lower()
    return raw in ("1", "true", "yes", "on")


def home_assistant_base_url() -> str:
    raw = (
        os.getenv("ALFA_AI_HOME_ASSISTANT_BASE_URL") or "http://apps"
    ).strip()
    return raw.rstrip("/")


def home_assistant_token_file() -> str:
    return (
        os.getenv("ALFA_AI_HOME_ASSISTANT_TOKEN_FILE")
        or "/app/secrets/home-assistant/long-lived.token"
    ).strip()


def home_assistant_token() -> str:
    path = home_assistant_token_file()
    if not os.path.isfile(path):
        raise HomeAssistantError(f"Home Assistant token file missing: {path}")
    with open(path, encoding="utf-8") as handle:
        token = handle.read().strip()
    if not token:
        raise HomeAssistantError(f"Home Assistant token file empty: {path}")
    return token


def home_assistant_token_present() -> bool:
    path = home_assistant_token_file()
    if not os.path.isfile(path):
        return False
    try:
        with open(path, encoding="utf-8") as handle:
            return bool(handle.read().strip())
    except OSError:
        return False


def home_assistant_ready() -> bool:
    return home_assistant_enabled() and home_assistant_token_present()


def validate_entity_id(entity_id: str) -> str:
    normalized = (entity_id or "").strip()
    if not ENTITY_ID_RE.match(normalized):
        raise ValueError(
            f"Invalid entity_id {entity_id!r} (expected domain.object_id per HA docs)"
        )
    return normalized


def ha_headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {home_assistant_token()}",
        "Content-Type": "application/json",
    }


def _raise_for_status(response: httpx.Response) -> None:
    if response.status_code == 401:
        raise HomeAssistantError("Home Assistant rejected the token (401)", status_code=401)
    if response.status_code == 404:
        raise HomeAssistantError(
            f"Home Assistant entity or path not found (404): {response.request.url.path}",
            status_code=404,
        )
    if response.status_code >= 400:
        raise HomeAssistantError(
            f"Home Assistant HTTP {response.status_code}",
            status_code=response.status_code,
        )


async def ha_get_state(entity_id: str) -> dict[str, Any]:
    eid = validate_entity_id(entity_id)
    url = f"{home_assistant_base_url()}/api/states/{eid}"
    async with httpx.AsyncClient(timeout=_HA_TIMEOUT_SEC) as client:
        response = await client.get(url, headers=ha_headers())
    _raise_for_status(response)
    data = response.json()
    if not isinstance(data, dict):
        raise HomeAssistantError("Unexpected Home Assistant state response shape")
    return data


async def ha_get_states(
    entity_ids: list[str], *, require_all: bool = True
) -> list[dict[str, Any]]:
    """Fetch HA states for entity_ids.

    Official collection GET: https://developers.home-assistant.io/docs/api/rest/
    When require_all=False, missing ids are omitted (single-id 404 returns []).
    """
    if not entity_ids:
        return []
    unique = []
    seen: set[str] = set()
    for raw in entity_ids:
        eid = validate_entity_id(raw)
        if eid not in seen:
            seen.add(eid)
            unique.append(eid)
    if len(unique) == 1:
        try:
            return [await ha_get_state(unique[0])]
        except HomeAssistantError as exc:
            if not require_all and exc.status_code == 404:
                return []
            raise
    url = f"{home_assistant_base_url()}/api/states"
    async with httpx.AsyncClient(timeout=_HA_TIMEOUT_SEC) as client:
        response = await client.get(url, headers=ha_headers())
    _raise_for_status(response)
    all_states = response.json()
    if not isinstance(all_states, list):
        raise HomeAssistantError("Unexpected Home Assistant /api/states response shape")
    by_id = {
        str(row.get("entity_id") or ""): row
        for row in all_states
        if isinstance(row, dict) and row.get("entity_id")
    }
    out: list[dict[str, Any]] = []
    for eid in unique:
        row = by_id.get(eid)
        if row is None:
            if require_all:
                raise HomeAssistantError(
                    f"Home Assistant entity not found: {eid}",
                    status_code=404,
                )
            continue
        out.append(row)
    return out


def validate_weather_entity_id(entity_id: str) -> str:
    eid = validate_entity_id(entity_id)
    if not eid.startswith("weather."):
        raise ValueError(
            f"Invalid weather entity_id {entity_id!r} (expected weather.* per HA weather-forecast card)"
        )
    return eid


def validate_forecast_type(forecast_type: str) -> str:
    normalized = (forecast_type or "daily").strip().lower()
    if normalized not in FORECAST_TYPES:
        raise ValueError(
            f"Invalid forecast type {forecast_type!r} (expected daily, hourly, or twice_daily)"
        )
    return normalized


def forecast_entries_from_response(payload: Any, entity_id: str) -> list[dict[str, Any]]:
    """Parse weather.get_forecasts REST return_response JSON into a forecast list."""
    if not isinstance(payload, dict):
        return []
    inner: Any = payload.get("service_response")
    if not isinstance(inner, dict):
        inner = payload
    block = inner.get(entity_id) if isinstance(inner.get(entity_id), dict) else None
    if block is None:
        for value in inner.values():
            if isinstance(value, dict) and isinstance(value.get("forecast"), list):
                block = value
                break
    if not isinstance(block, dict):
        return []
    forecast = block.get("forecast")
    if not isinstance(forecast, list):
        return []
    return [row for row in forecast if isinstance(row, dict)]


def compact_forecast_entries(
    entries: list[dict[str, Any]], *, limit: int = 5
) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for row in entries[: max(0, limit)]:
        compact: dict[str, Any] = {}
        for key in (
            "datetime",
            "condition",
            "temperature",
            "templow",
            "precipitation_probability",
            "cloud_coverage",
        ):
            if key in row:
                compact[key] = row[key]
        if compact:
            out.append(compact)
    return out


async def ha_get_forecasts(
    entity_id: str, forecast_type: str = "daily"
) -> dict[str, Any]:
    """POST weather.get_forecasts with official REST return_response.

    https://developers.home-assistant.io/docs/api/rest/
    https://www.home-assistant.io/integrations/weather/
    """
    eid = validate_weather_entity_id(entity_id)
    ftype = validate_forecast_type(forecast_type)
    url = (
        f"{home_assistant_base_url()}/api/services/weather/get_forecasts?return_response"
    )
    body = {"entity_id": eid, "type": ftype}
    async with httpx.AsyncClient(timeout=_HA_TIMEOUT_SEC) as client:
        response = await client.post(url, headers=ha_headers(), json=body)
    _raise_for_status(response)
    data = response.json()
    if not isinstance(data, dict):
        raise HomeAssistantError("Unexpected Home Assistant forecast response shape")
    return data


async def ha_call_service(domain: str, service: str, entity_id: str) -> Any:
    eid = validate_entity_id(entity_id)
    dom = (domain or "").strip().lower()
    svc = (service or "").strip().lower()
    if dom not in _CONTROL_DOMAINS:
        raise ValueError(f"Unsupported control domain {domain!r} (allow switch, light)")
    if svc not in ("turn_on", "turn_off"):
        raise ValueError(f"Unsupported service {service!r} (allow turn_on, turn_off)")
    url = f"{home_assistant_base_url()}/api/services/{dom}/{svc}"
    body = {"entity_id": eid}
    async with httpx.AsyncClient(timeout=_HA_TIMEOUT_SEC) as client:
        response = await client.post(url, headers=ha_headers(), json=body)
    _raise_for_status(response)
    try:
        return response.json()
    except Exception:
        return None


async def ha_call_helper_service(
    domain: str, service: str, entity_id: str, data: dict[str, Any]
) -> Any:
    """POST /api/services/{domain}/{service} for dump helpers only.

    Official: https://developers.home-assistant.io/docs/api/rest/
    input_number.set_value: https://www.home-assistant.io/integrations/input_number/
    input_select.select_option: https://www.home-assistant.io/integrations/input_select/
    """
    eid = validate_entity_id(entity_id)
    dom = (domain or "").strip().lower()
    svc = (service or "").strip().lower()
    payload = dict(data or {})
    if (dom, svc) == ("input_number", "set_value"):
        if "value" not in payload:
            raise ValueError("input_number.set_value requires data.value")
        body = {"entity_id": eid, "value": payload["value"]}
    elif (dom, svc) == ("input_select", "select_option"):
        option = str(payload.get("option") or "").strip()
        if not option:
            raise ValueError("input_select.select_option requires data.option")
        body = {"entity_id": eid, "option": option}
    else:
        raise ValueError(
            f"Unsupported helper service {dom}.{svc} "
            "(allow input_number.set_value, input_select.select_option)"
        )
    url = f"{home_assistant_base_url()}/api/services/{dom}/{svc}"
    async with httpx.AsyncClient(timeout=_HA_TIMEOUT_SEC) as client:
        response = await client.post(url, headers=ha_headers(), json=body)
    _raise_for_status(response)
    try:
        return response.json()
    except Exception:
        return None
