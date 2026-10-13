import asyncio
import math
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import HTTPException

from .config import Settings


def number(value, name, minimum=None, maximum=None):
    # Python bool is a subtype of int, but is not a weather measurement.
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(f"Invalid {name}")
    if minimum is not None and value < minimum:
        raise ValueError(f"Invalid {name}")
    if maximum is not None and value > maximum:
        raise ValueError(f"Invalid {name}")
    return value


def normalize_weather(data, config: Settings):
    """Validate the provider response before returning data to History."""
    if not isinstance(data, dict) or type(data.get("utc_offset_seconds")) is not int:
        raise ValueError("Invalid provider response")
    if data["utc_offset_seconds"] != 0:
        raise ValueError("Expected UTC")
    current, units = data.get("current"), data.get("current_units")
    if not isinstance(current, dict) or not isinstance(units, dict):
        raise ValueError("Missing current weather or units")
    expected_units = {
        "temperature_2m": "°C", "relative_humidity_2m": "%",
        "wind_speed_10m": "km/h", "time": "iso8601",
    }
    if any(units.get(key) != unit for key, unit in expected_units.items()):
        raise ValueError("Unexpected units")
    raw_time = current.get("time")
    if not isinstance(raw_time, str) or "T" not in raw_time:
        raise ValueError("Missing weather time")
    weather_time = datetime.fromisoformat(raw_time)
    # Open-Meteo ISO8601 may omit the suffix; the request and offset confirm UTC.
    if weather_time.tzinfo is None:
        weather_time = weather_time.replace(tzinfo=timezone.utc)
    if weather_time.utcoffset().total_seconds() != 0:
        raise ValueError("Expected UTC weather time")
    humidity = number(current.get("relative_humidity_2m"), "humidity", 0, 100)
    if int(humidity) != humidity:
        raise ValueError("Humidity must be an integer")
    return {
        "city": config.city_name,
        # Response coordinates identify a weather model grid cell near the requested city.
        "latitude": number(data.get("latitude"), "latitude", -90, 90),
        "longitude": number(data.get("longitude"), "longitude", -180, 180),
        "temperature_c": number(current.get("temperature_2m"), "temperature"),
        "humidity_percent": int(humidity),
        "wind_speed_kmh": number(current.get("wind_speed_10m"), "wind speed", 0),
        "weather_time": weather_time.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def normalize_temperature_history(data, config: Settings, days: int, now=None, since=None, until=None):
    """Validate hourly provider data and discard future forecast points."""
    now = now or datetime.now(timezone.utc)
    if not isinstance(data, dict) or type(data.get("utc_offset_seconds")) is not int or data["utc_offset_seconds"] != 0:
        raise ValueError("Expected UTC hourly data")
    hourly, units = data.get("hourly"), data.get("hourly_units")
    if not isinstance(hourly, dict) or not isinstance(units, dict) or units.get("time") != "iso8601" or units.get("temperature_2m") != "°C":
        raise ValueError("Missing hourly data or unexpected units")
    times, temperatures = hourly.get("time"), hourly.get("temperature_2m")
    if not isinstance(times, list) or not isinstance(temperatures, list) or not times or len(times) != len(temperatures) or len(times) > (days + 1) * 24:
        raise ValueError("Invalid hourly arrays")
    points = []
    previous = None
    since = since or (now - timedelta(days=days)).replace(minute=0, second=0, microsecond=0)
    until = until or now
    for raw_time, raw_temperature in zip(times, temperatures):
        if not isinstance(raw_time, str) or "T" not in raw_time:
            raise ValueError("Invalid hourly timestamp")
        weather_time = datetime.fromisoformat(raw_time)
        if weather_time.tzinfo is None:
            weather_time = weather_time.replace(tzinfo=timezone.utc)
        if weather_time.utcoffset().total_seconds() != 0 or weather_time.minute or weather_time.second or weather_time.microsecond:
            raise ValueError("Expected a UTC hour")
        if previous is not None and weather_time <= previous:
            raise ValueError("Hourly times must be strictly increasing")
        previous = weather_time
        if weather_time < since or weather_time > until:
            continue
        temperature = number(raw_temperature, "hourly temperature")
        points.append({"weather_time": weather_time.isoformat().replace("+00:00", "Z"), "temperature_c": temperature})
    if not points:
        raise ValueError("No historical temperature points")
    return {"city": config.city_name, "points": points}


async def provider_response(client, config, params):
    try:
        async with asyncio.timeout(config.timeout_seconds):
            response = await client.get(config.open_meteo_url, params=params)
            response.raise_for_status()
            if response.status_code != 200:
                raise ValueError("Unexpected provider status")
            return response.json()
    except (httpx.TimeoutException, TimeoutError) as exc:
        raise HTTPException(504, "Open-Meteo did not respond in time") from exc
    except httpx.HTTPError as exc:
        raise HTTPException(502, "Could not retrieve data from Open-Meteo") from exc
    except ValueError as exc:
        raise HTTPException(502, "Open-Meteo returned invalid JSON") from exc


def validate_range(start, end):
    since, until = datetime.fromisoformat(start), datetime.fromisoformat(end)
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    for value in (since, until):
        if value.tzinfo is None or value.utcoffset().total_seconds() != 0 or value.minute or value.second or value.microsecond:
            raise ValueError("Expected a UTC hour")
    if not now - timedelta(days=92) <= since <= until <= now:
        raise ValueError("Invalid hourly range")
    return since, until


async def fetch_current(client, config):
    data = await provider_response(client, config, {
        "latitude": config.city_lat, "longitude": config.city_lon,
        "current": "temperature_2m,relative_humidity_2m,wind_speed_10m",
        "temperature_unit": "celsius", "wind_speed_unit": "kmh",
        "timezone": "UTC", "timeformat": "iso8601",
    })
    return normalize_weather(data, config)


async def fetch_temperature_range(client, config, start, end):
    since, until = validate_range(start, end)
    data = await provider_response(client, config, {
        "latitude": config.city_lat, "longitude": config.city_lon,
        "hourly": "temperature_2m", "temperature_unit": "celsius",
        "timezone": "UTC", "timeformat": "iso8601",
        "start_hour": since.strftime("%Y-%m-%dT%H:%M"),
        "end_hour": until.strftime("%Y-%m-%dT%H:%M"),
    })
    result = normalize_temperature_history(data, config, 92, since=since, until=until)
    expected = int((until - since).total_seconds() / 3600) + 1
    if len(result["points"]) != expected:
        raise ValueError("Incomplete hourly range")
    for i, point in enumerate(result["points"]):
        if datetime.fromisoformat(point["weather_time"]) != since + timedelta(hours=i):
            raise ValueError("Missing hourly timestamp")
    return result
