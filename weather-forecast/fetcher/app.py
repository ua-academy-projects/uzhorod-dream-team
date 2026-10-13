import asyncio
import math
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, HTTPException, Query, Request

from .config import Settings, settings
from .provider import (number, normalize_weather, normalize_temperature_history,
                       provider_response, fetch_current, fetch_temperature_range, validate_range)

def create_app(config: Settings = settings):
    if config.rabbitmq_url:
        try:
            broker = urlsplit(config.rabbitmq_url)
            if broker.scheme not in ("amqp", "amqps") or not broker.hostname:
                raise ValueError("Invalid broker URL")
        except ValueError:
            raise ValueError("RABBITMQ_URL must be an AMQP(S) URL") from None
    if not math.isfinite(config.timeout_seconds) or config.timeout_seconds <= 0:
        raise ValueError("OPEN_METEO_TIMEOUT_SECONDS must be positive")
    number(config.city_lat, "CITY_LATITUDE", -90, 90)
    number(config.city_lon, "CITY_LONGITUDE", -180, 180)
    if not config.city_name.strip() or len(config.city_name) > 100:
        raise ValueError("CITY_NAME must contain 1–100 characters")

    @asynccontextmanager
    async def lifespan(app):
        async with httpx.AsyncClient(timeout=config.timeout_seconds) as client:
            app.state.client = client
            app.state.broker_ready = False
            worker = None
            if config.rabbitmq_url:
                from .worker import run_worker
                worker = asyncio.create_task(run_worker(client, config, app.state))
            try:
                yield
            finally:
                if worker:
                    worker.cancel()
                    try:
                        await asyncio.wait_for(worker, 15)
                    except (asyncio.CancelledError, TimeoutError):
                        pass

    app = FastAPI(title="Weather Fetcher", lifespan=lifespan)

    @app.get("/health")
    async def health(request: Request):
        if config.rabbitmq_url and not request.app.state.broker_ready:
            raise HTTPException(503, "RabbitMQ worker is disconnected")
        return {"status": "ok"}

    @app.get("/weather")
    async def weather(request: Request):
        try:
            return await fetch_current(request.app.state.client, config)
        except (ValueError, TypeError, OverflowError) as exc:
            raise HTTPException(502, "Open-Meteo returned invalid data") from exc

    @app.get("/temperature-history")
    async def temperature_history(request: Request, days: int = Query(30, ge=1, le=92),
                                  start: str | None = None, end: str | None = None):
        if start is not None or end is not None:
            try:
                validate_range(start, end)
            except (ValueError, TypeError):
                raise HTTPException(422, "start and end must be UTC hours within the past 92 days")
            try:
                return await fetch_temperature_range(request.app.state.client, config, start, end)
            except (ValueError, TypeError, OverflowError) as exc:
                raise HTTPException(502, "Open-Meteo returned invalid hourly data") from exc
        data = await provider_response(request.app.state.client, config, {
            "latitude": config.city_lat, "longitude": config.city_lon,
            "hourly": "temperature_2m", "past_days": days, "forecast_days": 1,
            "temperature_unit": "celsius", "timezone": "UTC", "timeformat": "iso8601",
        })
        try:
            return normalize_temperature_history(data, config, days)
        except (ValueError, TypeError, OverflowError) as exc:
            raise HTTPException(502, "Open-Meteo returned invalid hourly data") from exc

    return app


app = create_app()
