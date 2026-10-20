
import json
import logging
import os
import secrets
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from contextlib import asynccontextmanager

from services.history_client import HistoryClient

ROOT = Path(__file__).parent
load_dotenv(ROOT / ".env")
load_dotenv(ROOT.parent / ".env")

logger = logging.getLogger("ui")

APP_BACKEND = os.getenv("APP_BACKEND", "hybrid").strip().lower()
if APP_BACKEND not in {"hybrid", "postgres"}:
    raise RuntimeError("APP_BACKEND must be either 'hybrid' or 'postgres'")

app = FastAPI(title="Data Monitor")
app.mount("/static", StaticFiles(directory=ROOT / "static"), name="static")
templates = Jinja2Templates(directory=ROOT / "templates")

history_client = HistoryClient(
    os.getenv("HISTORY_SERVICE_URL", "http://history:8000")
)

redis = None
if APP_BACKEND == "hybrid":
    from redis.asyncio import Redis

    redis = Redis.from_url(
        os.getenv("REDIS_URL", "redis://192.168.56.13:6379/0"),
        decode_responses=True,
        socket_connect_timeout=2,
        socket_timeout=2,
    )


@asynccontextmanager
async def lifespan(_app):
    yield
    if redis is not None:
        await redis.aclose()


app.router.lifespan_context = lifespan

PREFERENCE_TTL = 60 * 60 * 24 * 30

DEFAULT_PREFERENCES = {
    "theme": "light",
    "language": "en",
    "font": "system",
}


async def get_session_id(request: Request, response: Response) -> str:
    session_id = request.cookies.get("dm_session")

    if not session_id or len(session_id) > 100:
        session_id = secrets.token_urlsafe(32)
        response.set_cookie(
            "dm_session",
            session_id,
            max_age=PREFERENCE_TTL,
            httponly=True,
            samesite="lax",
            secure=os.getenv("COOKIE_SECURE", "false").lower() == "true",
        )

    return session_id


def normalize_preferences(stored: dict | None) -> dict:
    stored = stored or {}

    return {
        "theme": stored.get("theme")
        if stored.get("theme") in ("light", "dark")
        else DEFAULT_PREFERENCES["theme"],
        "language": stored.get("language")
        if stored.get("language") in ("en", "ua")
        else DEFAULT_PREFERENCES["language"],
        "font": stored.get("font")
        if stored.get("font") in ("system", "serif", "mono")
        else DEFAULT_PREFERENCES["font"],
    }


@app.get("/")
async def index(request: Request):
    return templates.TemplateResponse(
        request=request,
        name="index.html",
    )


@app.get("/api/preferences")
async def get_preferences(request: Request, response: Response):
    session_id = await get_session_id(request, response)
    if APP_BACKEND == "postgres":
        try:
            stored = await history_client.preferences(session_id)
            return {"preferences": normalize_preferences(stored), "cache_available": True}
        except Exception:
            logger.exception("failed to load preferences from History")
            return JSONResponse(status_code=503, content={"error": "Unable to load preferences."})
    cache_available = True
    cache_key = f"preferences:{session_id}"

    # PostgreSQL is authoritative. This prevents stale Redis values
    # from being returned after Redis recovers from an outage.
    try:
        stored = await history_client.preferences(session_id)
        preferences = normalize_preferences(stored)
    except Exception:
        logger.exception("failed to load preferences from History")

        # If PostgreSQL is unavailable, Redis can still serve a cached
        # value as a last-resort read fallback.
        try:
            saved = await redis.get(cache_key)

            if saved:
                preferences = normalize_preferences(json.loads(saved))
                return {
                    "preferences": preferences,
                    "cache_available": True,
                    "storage_fallback": "redis",
                }
        except Exception:
            logger.exception("Redis fallback also failed")

        return JSONResponse(
            status_code=503,
            content={"error": "Unable to load preferences."},
        )

    # Refresh Redis from PostgreSQL, including after Redis recovers.
    try:
        await redis.setex(
            cache_key,
            PREFERENCE_TTL,
            json.dumps(preferences),
        )
    except Exception:
        logger.exception("failed to refresh Redis cache")
        cache_available = False

    return {
        "preferences": preferences,
        "cache_available": cache_available,
    }


@app.put("/api/preferences")
async def put_preferences(request: Request, response: Response):
    session_id = await get_session_id(request, response)
    if APP_BACKEND == "postgres":
        try:
            payload = await request.json()
            saved = await history_client.save_preferences(session_id, normalize_preferences(payload))
            return {"preferences": normalize_preferences(saved), "cache_available": True}
        except Exception:
            logger.exception("failed to save preferences to History")
            return JSONResponse(status_code=503, content={"error": "Unable to save preferences."})
    cache_key = f"preferences:{session_id}"

    try:
        payload = await request.json()
        preferences = normalize_preferences(payload)

        # Save to PostgreSQL first so a Redis outage does not lose
        # the user's changes.
        saved = await history_client.save_preferences(
            session_id,
            preferences,
        )
        saved = normalize_preferences(saved)

    except Exception:
        logger.exception("failed to save preferences to History")
        return JSONResponse(
            status_code=503,
            content={"error": "Unable to save preferences."},
        )

    cache_available = True

    try:
        await redis.setex(
            cache_key,
            PREFERENCE_TTL,
            json.dumps(saved),
        )
    except Exception:
        logger.exception("failed to update Redis cache")
        cache_available = False

    return {
        "preferences": saved,
        "cache_available": cache_available,
    }


@app.get("/api/sources")
async def api_sources():
    try:
        return await history_client.sources()
    except Exception:
        logger.exception("failed to load sources")
        return JSONResponse(
            status_code=503,
            content={
                "error": "Unable to load sources. Please try again later."
            },
        )


@app.get("/api/history")
async def api_history(source: str = "btc"):
    try:
        return await history_client.history(source)
    except Exception:
        logger.exception("failed to load history for source %s", source)
        return JSONResponse(
            status_code=503,
            content={
                "error": "Unable to load historical data. Please try again later."
            },
        )
