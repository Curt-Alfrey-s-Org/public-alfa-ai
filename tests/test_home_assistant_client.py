"""Home Assistant REST client unit tests."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.ops.home_assistant_client import (
    ENTITY_ID_RE,
    HomeAssistantError,
    compact_forecast_entries,
    forecast_entries_from_response,
    ha_call_service,
    ha_get_forecasts,
    ha_get_state,
    ha_get_states,
    ha_headers,
    home_assistant_enabled,
    validate_entity_id,
    validate_forecast_type,
    validate_weather_entity_id,
)


def test_entity_id_regex_accepts_valid_ids() -> None:
    assert ENTITY_ID_RE.match("switch.trailer_plug_a")
    assert ENTITY_ID_RE.match("sensor.battery_1_soc")
    with pytest.raises(ValueError):
        validate_entity_id("Bad.Entity")
    with pytest.raises(ValueError):
        validate_entity_id("")


def test_home_assistant_enabled_truthy() -> None:
    with patch.dict("os.environ", {"ALFA_AI_HOME_ASSISTANT_ENABLED": "1"}):
        assert home_assistant_enabled() is True
    with patch.dict("os.environ", {"ALFA_AI_HOME_ASSISTANT_ENABLED": "0"}, clear=False):
        assert home_assistant_enabled() is False


def test_ha_headers_bearer_no_token_in_repr() -> None:
    with patch(
        "src.ops.home_assistant_client.home_assistant_token",
        return_value="secret-token-value",
    ):
        headers = ha_headers()
    assert headers["Authorization"] == "Bearer secret-token-value"
    assert headers["Content-Type"] == "application/json"
    assert "secret-token-value" not in repr(HomeAssistantError("fail"))


def test_ha_call_service_posts_correct_url() -> None:
    async def _run() -> None:
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = []
        mock_client = AsyncMock()
        mock_client.post = AsyncMock(return_value=mock_response)
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)

        with patch(
            "src.ops.home_assistant_client.home_assistant_token",
            return_value="tok",
        ), patch(
            "src.ops.home_assistant_client.home_assistant_base_url",
            return_value="http://apps",
        ), patch(
            "src.ops.home_assistant_client.httpx.AsyncClient",
            return_value=mock_client,
        ):
            await ha_call_service("switch", "turn_on", "switch.trailer_plug_a")

        mock_client.post.assert_awaited_once()
        call_args = mock_client.post.await_args
        assert call_args.args[0] == "http://apps/api/services/switch/turn_on"
        assert call_args.kwargs["json"] == {"entity_id": "switch.trailer_plug_a"}
        assert call_args.kwargs["headers"]["Authorization"].startswith("Bearer ")

    asyncio.run(_run())


def test_ha_get_state_401_raises_without_token_leak() -> None:
    async def _run() -> None:
        mock_response = MagicMock()
        mock_response.status_code = 401
        mock_response.request.url.path = "/api/states/switch.foo"
        mock_client = AsyncMock()
        mock_client.get = AsyncMock(return_value=mock_response)
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)

        with patch(
            "src.ops.home_assistant_client.home_assistant_token",
            return_value="secret-token-value",
        ), patch(
            "src.ops.home_assistant_client.home_assistant_base_url",
            return_value="http://apps",
        ), patch(
            "src.ops.home_assistant_client.httpx.AsyncClient",
            return_value=mock_client,
        ):
            with pytest.raises(HomeAssistantError, match="401") as exc_info:
                await ha_get_state("switch.foo")
        assert "secret-token-value" not in str(exc_info.value)

    asyncio.run(_run())


def test_validate_weather_entity_and_forecast_type() -> None:
    assert validate_weather_entity_id("weather.417373300314") == "weather.417373300314"
    with pytest.raises(ValueError, match="weather"):
        validate_weather_entity_id("climate.417373300314")
    assert validate_forecast_type("hourly") == "hourly"
    with pytest.raises(ValueError, match="forecast type"):
        validate_forecast_type("weekly")


def test_forecast_entries_from_response_and_compact() -> None:
    payload = {
        "service_response": {
            "weather.417373300314": {
                "forecast": [
                    {
                        "datetime": "2026-09-18T00:00:00+00:00",
                        "condition": "partlycloudy",
                        "temperature": 86,
                        "extra": "drop-me",
                    },
                    {"datetime": "2026-09-19T00:00:00+00:00", "condition": "rainy"},
                ]
            }
        }
    }
    entries = forecast_entries_from_response(payload, "weather.417373300314")
    compact = compact_forecast_entries(entries, limit=1)
    assert len(compact) == 1
    assert compact[0]["condition"] == "partlycloudy"
    assert "extra" not in compact[0]


def test_ha_get_forecasts_posts_return_response() -> None:
    async def _run() -> None:
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {"service_response": {}}
        mock_client = AsyncMock()
        mock_client.post = AsyncMock(return_value=mock_response)
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)

        with patch(
            "src.ops.home_assistant_client.home_assistant_token",
            return_value="tok",
        ), patch(
            "src.ops.home_assistant_client.home_assistant_base_url",
            return_value="http://apps",
        ), patch(
            "src.ops.home_assistant_client.httpx.AsyncClient",
            return_value=mock_client,
        ):
            await ha_get_forecasts("weather.417373300314", "daily")

        mock_client.post.assert_awaited_once()
        call_args = mock_client.post.await_args
        assert (
            call_args.args[0]
            == "http://apps/api/services/weather/get_forecasts?return_response"
        )
        assert call_args.kwargs["json"] == {
            "entity_id": "weather.417373300314",
            "type": "daily",
        }

    asyncio.run(_run())


def test_ha_get_states_require_all_true_raises_on_missing() -> None:
    async def _run() -> None:
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = [
            {"entity_id": "sensor.present", "state": "1"},
        ]
        mock_client = AsyncMock()
        mock_client.get = AsyncMock(return_value=mock_response)
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)

        with patch(
            "src.ops.home_assistant_client.home_assistant_token",
            return_value="tok",
        ), patch(
            "src.ops.home_assistant_client.home_assistant_base_url",
            return_value="http://apps",
        ), patch(
            "src.ops.home_assistant_client.httpx.AsyncClient",
            return_value=mock_client,
        ):
            with pytest.raises(HomeAssistantError, match="not found"):
                await ha_get_states(
                    ["sensor.present", "sensor.missing"],
                    require_all=True,
                )

    asyncio.run(_run())


def test_ha_get_states_require_all_false_omits_missing() -> None:
    async def _run() -> None:
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = [
            {"entity_id": "sensor.present", "state": "1"},
        ]
        mock_client = AsyncMock()
        mock_client.get = AsyncMock(return_value=mock_response)
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)

        with patch(
            "src.ops.home_assistant_client.home_assistant_token",
            return_value="tok",
        ), patch(
            "src.ops.home_assistant_client.home_assistant_base_url",
            return_value="http://apps",
        ), patch(
            "src.ops.home_assistant_client.httpx.AsyncClient",
            return_value=mock_client,
        ):
            rows = await ha_get_states(
                ["sensor.present", "sensor.missing"],
                require_all=False,
            )

        assert len(rows) == 1
        assert rows[0]["entity_id"] == "sensor.present"

    asyncio.run(_run())


def test_ha_get_states_single_missing_require_all_false_returns_empty() -> None:
    async def _run() -> None:
        mock_response = MagicMock()
        mock_response.status_code = 404
        mock_response.request.url.path = "/api/states/sensor.missing"
        mock_client = AsyncMock()
        mock_client.get = AsyncMock(return_value=mock_response)
        mock_client.__aenter__ = AsyncMock(return_value=mock_client)
        mock_client.__aexit__ = AsyncMock(return_value=None)

        with patch(
            "src.ops.home_assistant_client.home_assistant_token",
            return_value="tok",
        ), patch(
            "src.ops.home_assistant_client.home_assistant_base_url",
            return_value="http://apps",
        ), patch(
            "src.ops.home_assistant_client.httpx.AsyncClient",
            return_value=mock_client,
        ):
            rows = await ha_get_states(["sensor.missing"], require_all=False)

        assert rows == []

    asyncio.run(_run())
