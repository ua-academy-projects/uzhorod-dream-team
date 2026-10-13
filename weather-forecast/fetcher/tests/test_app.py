import asyncio
import copy
import json
import threading
import time
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import httpx
import pytest

from fetcher.app import create_app, normalize_weather, normalize_temperature_history
from fetcher.config import Settings


def call_endpoint(config, path="/weather"):
    async def request():
        app = create_app(config)
        async with app.router.lifespan_context(app):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                return await client.get(path)

    return asyncio.run(request())


def provider_data():
    return {
        "latitude": 48.6167, "longitude": 22.3, "utc_offset_seconds": 0,
        "current_units": {"time": "iso8601", "temperature_2m": "°C",
                          "relative_humidity_2m": "%", "wind_speed_10m": "km/h"},
        "current": {"time": "2026-09-30T09:15", "temperature_2m": 16.2,
                    "relative_humidity_2m": 70, "wind_speed_10m": 9.4},
    }


@pytest.fixture
def provider():
    state = {"status": 200, "body": json.dumps(provider_data()), "delay": 0, "query": None}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            state["query"] = parse_qs(urlparse(self.path).query)
            time.sleep(state["delay"])
            self.send_response(state["status"])
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            try:
                self.wfile.write(state["body"].encode())
            except (BrokenPipeError, ConnectionResetError):
                pass  # The client has already timed out.

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    state["url"] = f"http://127.0.0.1:{server.server_port}"
    yield state
    server.shutdown()
    server.server_close()
    thread.join()


def test_normalization():
    weather = normalize_weather(provider_data(), Settings())
    assert weather == {
        "city": "Uzhhorod", "latitude": 48.6167, "longitude": 22.3,
        "temperature_c": 16.2, "humidity_percent": 70, "wind_speed_kmh": 9.4,
        "weather_time": "2026-09-30T09:15:00Z",
    }


@pytest.mark.parametrize("field,value", [
    ("temperature_2m", None), ("temperature_2m", "16.2"),
    ("temperature_2m", float("nan")), ("relative_humidity_2m", 101),
    ("relative_humidity_2m", True), ("wind_speed_10m", -1),
    ("time", "2026-09-30T09:15:00+03:00"),
])
def test_reject_invalid_fields(field, value):
    data = copy.deepcopy(provider_data())
    data["current"][field] = value
    with pytest.raises(ValueError):
        normalize_weather(data, Settings())


def test_weather_endpoint_and_explicit_units(provider):
    config = replace(Settings(), open_meteo_url=provider["url"])
    assert call_endpoint(config, "/health").status_code == 200
    response = call_endpoint(config)
    assert response.status_code == 200
    assert response.json()["weather_time"] == "2026-09-30T09:15:00Z"
    assert provider["query"]["timezone"] == ["UTC"]
    assert provider["query"]["temperature_unit"] == ["celsius"]
    assert provider["query"]["wind_speed_unit"] == ["kmh"]
    assert provider["query"]["current"] == ["temperature_2m,relative_humidity_2m,wind_speed_10m"]


@pytest.mark.parametrize("status,body", [
    (503, "{}"), (200, "not json"), (200, "{}"), (200, "[]"),
])
def test_provider_errors(provider, status, body):
    provider.update(status=status, body=body)
    config = replace(Settings(), open_meteo_url=provider["url"])
    response = call_endpoint(config)
    assert response.status_code == 502
    assert isinstance(response.json()["detail"], str)


def test_provider_timeout(provider):
    provider["delay"] = 0.2
    config = replace(Settings(), open_meteo_url=provider["url"], timeout_seconds=0.05)
    response = call_endpoint(config)
    assert response.status_code == 504


def test_provider_connection_failure():
    # Port 0 cannot be used for a remote HTTP service.
    config = replace(Settings(), open_meteo_url="http://127.0.0.1:0", timeout_seconds=0.05)
    response = call_endpoint(config)
    assert response.status_code == 502


def hourly_data(now):
    hour = now.replace(minute=0, second=0, microsecond=0)
    return {
        "utc_offset_seconds": 0,
        "hourly_units": {"time": "iso8601", "temperature_2m": "°C"},
        "hourly": {
            "time": [(hour + timedelta(hours=offset)).strftime("%Y-%m-%dT%H:%M") for offset in (-1, 0, 1)],
            "temperature_2m": [10, 11, 12],
        },
    }


def test_temperature_history_excludes_future():
    now = datetime(2026, 10, 8, 9, 30, tzinfo=timezone.utc)
    result = normalize_temperature_history(hourly_data(now), Settings(), 30, now)
    assert result["city"] == "Uzhhorod"
    assert result["points"] == [
        {"weather_time": "2026-10-08T08:00:00Z", "temperature_c": 10},
        {"weather_time": "2026-10-08T09:00:00Z", "temperature_c": 11},
    ]


@pytest.mark.parametrize("invalid", ["mismatched arrays", "null temperature", "wrong units", "duplicate times"])
def test_invalid_temperature_history(invalid):
    now = datetime(2026, 10, 8, 9, 30, tzinfo=timezone.utc)
    data = hourly_data(now)
    if invalid == "mismatched arrays":
        data["hourly"]["temperature_2m"].pop()
    elif invalid == "null temperature":
        data["hourly"]["temperature_2m"][0] = None
    elif invalid == "wrong units":
        data["hourly_units"]["temperature_2m"] = "°F"
    else:
        data["hourly"]["time"][1] = data["hourly"]["time"][0]
    with pytest.raises(ValueError):
        normalize_temperature_history(data, Settings(), 30, now)


def test_temperature_history_endpoint(provider):
    provider["body"] = json.dumps(hourly_data(datetime.now(timezone.utc)))
    config = replace(Settings(), open_meteo_url=provider["url"])
    response = call_endpoint(config, "/temperature-history?days=30")
    assert response.status_code == 200
    assert len(response.json()["points"]) == 2
    assert provider["query"]["past_days"] == ["30"]
    assert provider["query"]["forecast_days"] == ["1"]
    assert provider["query"]["hourly"] == ["temperature_2m"]
    assert provider["query"]["timezone"] == ["UTC"]
    assert provider["query"]["temperature_unit"] == ["celsius"]
    assert call_endpoint(config, "/temperature-history?days=93").status_code == 422


def test_temperature_range_and_location(provider):
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    config = replace(Settings(), open_meteo_url=provider["url"])
    assert call_endpoint(config, "/health").status_code == 200
    assert provider["query"] is None
    provider["body"] = json.dumps(hourly_data(now))
    start = (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
    end = now.isoformat().replace("+00:00", "Z")
    response = call_endpoint(config, f"/temperature-history?start={start}&end={end}")
    assert response.status_code == 200
    assert len(response.json()["points"]) == 2
    assert provider["query"]["start_hour"] == [(now - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M")]
    assert provider["query"]["end_hour"] == [now.strftime("%Y-%m-%dT%H:%M")]
    assert "past_days" not in provider["query"]
    for query in (f"start={start}", f"start={end}&end={start}", "start=bad&end=bad",
                  "start=2026-01-01T00:00&end=2026-01-02T00:00"):
        assert call_endpoint(config, f"/temperature-history?{query}").status_code == 422
    provider["body"] = json.dumps({**hourly_data(now), "hourly": {"time": [now.strftime("%Y-%m-%dT%H:%M")], "temperature_2m": [11]}})
    assert call_endpoint(config, f"/temperature-history?start={start}&end={end}").status_code == 502
