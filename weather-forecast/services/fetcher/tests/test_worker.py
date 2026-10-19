import asyncio
import json
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import httpx
import pytest

from fetcher.config import Settings
from fetcher.workers.jobs import execute_job
from fetcher.workers.rabbitmq import handle_message
from tests.test_app import provider


def request(kind="current_weather"):
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    return {"request_id": str(uuid4()), "type": kind, "city": "Uzhhorod",
            "latitude": 48.6167, "longitude": 22.3,
            "expires_at": (datetime.now(timezone.utc) + timedelta(seconds=120)).isoformat(),
            "ranges": [{"start": (now - timedelta(hours=1)).isoformat(), "end": now.isoformat()}]}


def run(job, config):
    async def call():
        async with httpx.AsyncClient() as client:
            return await execute_job(job, client, config)
    return asyncio.run(call())


def test_current_job_and_provider_failure(provider):
    config = replace(Settings(), open_meteo_url=provider["url"])
    job = request()
    result = run(job, config)
    assert result["status"] == "completed"
    assert result["request_id"] == job["request_id"]
    assert result["data"]["city"] == "Uzhhorod"
    assert provider["query"]["latitude"] == ["48.6167"]
    provider["status"] = 503
    failed = run(job, config)
    assert failed["status"] == "failed"
    assert failed["error"]["code"] == "provider_unavailable"
    assert "data" not in failed


def test_hourly_job_is_all_or_nothing(provider):
    job = request("temperature_history")
    start = datetime.fromisoformat(job["ranges"][0]["start"])
    end = datetime.fromisoformat(job["ranges"][0]["end"])
    data = {"utc_offset_seconds": 0, "hourly_units": {"time": "iso8601", "temperature_2m": "°C"},
            "hourly": {"time": [start.strftime("%Y-%m-%dT%H:%M"), end.strftime("%Y-%m-%dT%H:%M")],
                       "temperature_2m": [10, 11]}}
    provider["body"] = json.dumps(data)
    config = replace(Settings(), open_meteo_url=provider["url"])
    result = run(job, config)
    assert result["status"] == "completed"
    assert len(result["data"]["points"]) == 2
    # The first range succeeds, but the second hour is missing.
    job["ranges"] = [{"start": start.isoformat(), "end": start.isoformat()},
                     {"start": end.isoformat(), "end": end.isoformat()}]
    data["hourly"]["time"].pop()
    data["hourly"]["temperature_2m"].pop()
    provider["body"] = json.dumps(data)
    result = run(job, config)
    assert result["status"] == "failed"
    assert "data" not in result
    assert provider["query"]["start_hour"] == [end.strftime("%Y-%m-%dT%H:%M")]


def test_expired_task_does_not_call_provider(provider):
    job = request()
    job["expires_at"] = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
    result = run(job, replace(Settings(), open_meteo_url=provider["url"]))
    assert result["error"]["code"] == "job_expired"
    assert provider["query"] is None


def test_ack_only_after_confirm_and_redelivery(provider):
    job = request()

    class Message:
        body = json.dumps(job).encode()
        correlation_id = job["request_id"]
        type = job["type"]
        acknowledgements = 0

        async def ack(self):
            self.acknowledgements += 1

        async def reject(self, requeue=False):
            pytest.fail("valid job rejected")

    async def call():
        message = Message()
        events = []

        async def failed_publish(response):
            raise ConnectionError("confirm lost")

        async def confirmed_publish(response):
            assert message.acknowledgements == 0
            events.append(response["request_id"])

        async with httpx.AsyncClient() as client:
            config = replace(Settings(), open_meteo_url=provider["url"])
            with pytest.raises(ConnectionError):
                await handle_message(message, failed_publish, client, config)
            assert message.acknowledgements == 0
            await handle_message(message, confirmed_publish, client, config)
            assert message.acknowledgements == 1
            assert events == [job["request_id"]]

    asyncio.run(call())
