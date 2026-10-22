"""Fetching the current temperature from Open-Meteo."""

import logging
from datetime import datetime, timezone

import httpx

logger = logging.getLogger(__name__)

OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"


class WeatherError(Exception):
    """Real weather data could not be fetched."""


def to_rfc3339_utc(moment: datetime) -> str:
    """Convert a time to a string like 2026-10-04T21:00:00Z."""
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fetch_current_temperature(
    city: str, latitude: float, longitude: float, timeout_seconds: float
) -> dict:
    """Return the current temperature or raise WeatherError.

    Never returns made-up data: if something goes wrong,
    we log it and raise an error.
    """
    params = {
        "latitude": latitude,
        "longitude": longitude,
        "current": "temperature_2m",
        # Ask for the time in UTC right away.
        "timezone": "UTC",
    }

    try:
        response = httpx.get(OPEN_METEO_URL, params=params, timeout=timeout_seconds)
        # Raises HTTPStatusError if the status is 4xx or 5xx.
        response.raise_for_status()
        current = response.json()["current"]
        temperature = current["temperature_2m"]
        observed_raw = current["time"]  # e.g. "2026-10-04T21:00"
        observed_at = datetime.fromisoformat(observed_raw)
        if observed_at.tzinfo is None:
            # Without a time zone, treat the value as UTC, because that is what we asked the API for.
            observed_at = observed_at.replace(tzinfo=timezone.utc)
        else:
            observed_at = observed_at.astimezone(timezone.utc)
    except httpx.TimeoutException as error:
        logger.error("Open-Meteo не відповів за %s с: %r", timeout_seconds, error)
        raise WeatherError("Open-Meteo timeout") from error
    except httpx.HTTPStatusError as error:
        logger.error("Open-Meteo повернув помилку HTTP %s", error.response.status_code)
        raise WeatherError("Open-Meteo HTTP error") from error
    except httpx.RequestError as error:
        logger.error("Не вдалося з'єднатися з Open-Meteo: %r", error)
        raise WeatherError("Open-Meteo connection error") from error
    except (ValueError, KeyError, TypeError) as error:
        logger.error("Open-Meteo повернув відповідь у неочікуваному форматі: %r", error)
        raise WeatherError("Open-Meteo bad response") from error

    if temperature is None:
        logger.error("Open-Meteo не повернув температуру")
        raise WeatherError("Open-Meteo returned no temperature")

    fetched_at = datetime.now(timezone.utc)

    logger.info("%s: %s °C (виміряно %s)", city, temperature, to_rfc3339_utc(observed_at))

    return {
        "city": city,
        "temperature_c": temperature,
        "observed_at": to_rfc3339_utc(observed_at),
        "fetched_at": to_rfc3339_utc(fetched_at),
    }
