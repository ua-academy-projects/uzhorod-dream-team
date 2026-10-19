"""Weather job validation and execution shared by both queue backends."""
import asyncio
from dataclasses import replace
from datetime import datetime, timezone

from fastapi import HTTPException

from ..provider import number, fetch_current, fetch_temperature_range, validate_range


async def execute_job(job, client, config):
    response = {"request_id": job["request_id"], "type": job.get("type"), "status": "failed"}
    try:
        expires = datetime.fromisoformat(job["expires_at"])
        if expires.tzinfo is None or expires.utcoffset().total_seconds() != 0:
            raise ValueError("Expected UTC deadline")
        remaining = (expires - datetime.now(timezone.utc)).total_seconds()
        if remaining <= 0:
            response["error"] = {"code": "job_expired", "message": "Job deadline expired"}
            return response
        city = job["city"]
        if not isinstance(city, str) or not city.strip() or len(city) > 100:
            raise ValueError("Invalid city")
        location = replace(config, city_name=city,
                           city_lat=number(job["latitude"], "latitude", -90, 90),
                           city_lon=number(job["longitude"], "longitude", -180, 180))
        async with asyncio.timeout(min(remaining, 120)):
            if job["type"] == "current_weather":
                data = await fetch_current(client, location)
            elif job["type"] == "temperature_history":
                ranges = job["ranges"]
                if not isinstance(ranges, list) or not 1 <= len(ranges) <= 4:
                    raise ValueError("Expected 1–4 ranges")
                previous = None
                for interval in ranges:
                    start, end = validate_range(interval["start"], interval["end"])
                    if previous is not None and start <= previous:
                        raise ValueError("Overlapping or unsorted ranges")
                    previous = end
                points = []
                for interval in ranges:
                    part = await fetch_temperature_range(client, location, interval["start"], interval["end"])
                    points.extend(part["points"])
                data = {"city": city, "points": points}
            else:
                raise ValueError("Unknown job type")
        response.update(status="completed", data=data)
    except HTTPException as exc:
        code = "provider_timeout" if exc.status_code == 504 else "provider_unavailable"
        response["error"] = {"code": code, "message": exc.detail}
    except TimeoutError:
        response["error"] = {"code": "job_expired", "message": "Job processing timed out"}
    except (KeyError, ValueError, TypeError, OverflowError):
        response["error"] = {"code": "invalid_data", "message": "Invalid job or incomplete provider data"}
    return response
