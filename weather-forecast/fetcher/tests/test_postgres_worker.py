import asyncio
import json
import os
from contextlib import asynccontextmanager
from dataclasses import replace
from pathlib import Path
from uuid import UUID, uuid4

import asyncpg
import httpx
import pytest

from fetcher.app import create_app
from fetcher.config import Settings
from fetcher.postgres_worker import (
    DeliveryLost, claim_request, finish_request, process_request, extend_visibility,
)
from fetcher.tests.test_app import provider
from fetcher.tests.test_worker import request


@pytest.fixture
def postgres_schema():
    url = os.getenv("TEST_DATABASE_URL")
    if not url:
        pytest.skip("set TEST_DATABASE_URL to an isolated PostgreSQL test database")
    schema = "fetcher_queue_test_" + uuid4().hex

    async def setup():
        connection = await asyncpg.connect(url, timeout=5)
        try:
            await connection.execute(f"CREATE SCHEMA {schema}")
            await connection.execute(f"SET search_path TO {schema},public")
            migrations = Path(__file__).resolve().parents[2] / "migrations"
            for name in ("004_weather_jobs.sql", "005_postgres_queue.sql"):
                async with connection.transaction():
                    await connection.execute((migrations / name).read_text())
            await connection.execute("TRUNCATE pgmq.q_weather_requests, pgmq.q_weather_responses")
        finally:
            await connection.close()

    async def cleanup():
        connection = await asyncpg.connect(url, timeout=5)
        try:
            await connection.execute("TRUNCATE pgmq.q_weather_requests, pgmq.q_weather_responses")
            await connection.execute("ALTER TABLE pgmq.q_weather_responses DROP CONSTRAINT IF EXISTS reject_response")
            await connection.execute(f"DROP SCHEMA {schema} CASCADE")
        finally:
            await connection.close()

    asyncio.run(setup())
    try:
        yield url, schema
    finally:
        asyncio.run(cleanup())


@asynccontextmanager
async def queue_pool(database):
    url, schema = database
    pool = await asyncpg.create_pool(
        url, min_size=1, max_size=4, timeout=5, command_timeout=5,
        server_settings={"search_path": schema + ",public", "timezone": "UTC"})
    try:
        yield pool
    finally:
        await pool.close()


async def enqueue(pool, job):
    from datetime import datetime
    from uuid import UUID

    async with pool.acquire() as connection:
        async with connection.transaction():
            await connection.execute("""
INSERT INTO weather_jobs (request_id,type,status,request_payload,expires_at,backend)
VALUES ($1,$2,'queued',$3,$4,'postgres')
""", UUID(job["request_id"]), job["type"], json.dumps(job), datetime.fromisoformat(job["expires_at"]))
            await connection.execute("SELECT pgmq.send('weather_requests', $1::jsonb)", json.dumps(job))


def test_reservation_excludes_competitors_and_fences_old_worker(postgres_schema):
    async def check():
        async with queue_pool(postgres_schema) as pool:
            job = request()
            await enqueue(pool, job)
            claims = await asyncio.gather(*(claim_request(pool) for _ in range(8)))
            messages = [message for message in claims if message is not None]
            assert len(messages) == 1
            old = messages[0]
            await pool.execute("UPDATE pgmq.q_weather_requests SET vt=NOW()-INTERVAL '1 second'")
            current = await claim_request(pool)
            assert current["read_ct"] > old["read_ct"]
            with pytest.raises(DeliveryLost):
                await extend_visibility(pool, old)
            response = {"request_id": job["request_id"], "type": job["type"], "status": "completed"}
            with pytest.raises(DeliveryLost):
                await finish_request(pool, old, response)
            assert await pool.fetchval("SELECT count(*) FROM pgmq.q_weather_responses") == 0
            await extend_visibility(pool, current)
            await finish_request(pool, current, response)
            with pytest.raises(DeliveryLost):
                await finish_request(pool, current, response)
            assert await pool.fetchval("SELECT count(*) FROM pgmq.q_weather_requests") == 0
            assert await pool.fetchval("SELECT count(*) FROM pgmq.q_weather_responses") == 1
    asyncio.run(check())


def test_response_failure_keeps_request_and_cancellation_allows_retry(postgres_schema):
    async def check():
        async with queue_pool(postgres_schema) as pool:
            job = request()
            await enqueue(pool, job)
            message = await claim_request(pool)
            await pool.execute("ALTER TABLE pgmq.q_weather_responses ADD CONSTRAINT reject_response CHECK (false)")
            with pytest.raises(asyncpg.CheckViolationError):
                await finish_request(pool, message, {"status": "completed"})
            assert await pool.fetchval("SELECT count(*) FROM pgmq.q_weather_requests") == 1
            await pool.execute("ALTER TABLE pgmq.q_weather_responses DROP CONSTRAINT reject_response")

            started = asyncio.Event()

            async def slow_provider(request):
                started.set()
                await asyncio.Future()

            async with httpx.AsyncClient(transport=httpx.MockTransport(slow_provider)) as client:
                task = asyncio.create_task(process_request(pool, message, client, Settings()))
                await asyncio.wait_for(started.wait(), 5)
                task.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await task
            assert await pool.fetchval("SELECT count(*) FROM pgmq.q_weather_responses") == 0
            await pool.execute("UPDATE pgmq.q_weather_requests SET vt=NOW()-INTERVAL '1 second'")
            assert await claim_request(pool) is not None
    asyncio.run(check())


def test_processing_current_and_hourly_requests(postgres_schema, provider):
    async def check():
        async with queue_pool(postgres_schema) as pool:
            async with httpx.AsyncClient() as client:
                config = replace(Settings(), backend="postgres", open_meteo_url=provider["url"])
                for kind in ("current_weather", "temperature_history"):
                    job = request(kind)
                    if kind == "temperature_history":
                        from datetime import datetime
                        hours = [datetime.fromisoformat(job["ranges"][0][key]).strftime("%Y-%m-%dT%H:%M")
                                 for key in ("start", "end")]
                        provider["body"] = json.dumps({"utc_offset_seconds": 0,
                            "hourly_units": {"time": "iso8601", "temperature_2m": "°C"},
                            "hourly": {"time": hours, "temperature_2m": [10, 11]}})
                    await enqueue(pool, job)
                    message = await claim_request(pool)
                    await process_request(pool, message, client, config)
                    row = await pool.fetchrow("SELECT message FROM pgmq.q_weather_responses WHERE message->>'request_id'=$1", job["request_id"])
                    response = json.loads(row["message"])
                    assert response["request_id"] == job["request_id"]
                    assert response["status"] == "completed"
                    if kind == "temperature_history":
                        assert len(response["data"]["points"]) == 2
                    await pool.execute("UPDATE weather_jobs SET status='completed' WHERE request_id=$1", UUID(job["request_id"]))
                assert await pool.fetchval("SELECT count(*) FROM pgmq.q_weather_requests") == 0
    asyncio.run(check())


def test_expired_and_malformed_requests(postgres_schema):
    async def check():
        async with queue_pool(postgres_schema) as pool:
            await enqueue(pool, request())
            await pool.execute("UPDATE pgmq.q_weather_requests SET message=jsonb_set(message,'{expires_at}',to_jsonb((now()-interval '1 second')::text))")
            message = await claim_request(pool)
            async with httpx.AsyncClient() as client:
                await process_request(pool, message, client, Settings())
            assert await pool.fetchval("SELECT count(*) FROM pgmq.q_weather_requests") == 0
            await pool.execute("SELECT pgmq.send('weather_requests', '{}'::jsonb)")
            message = await claim_request(pool)
            async with httpx.AsyncClient() as client:
                await process_request(pool, message, client, Settings())
            assert await pool.fetchval("SELECT count(*) FROM pgmq.q_weather_requests") == 0
    asyncio.run(check())


def test_backend_configuration_and_health(monkeypatch):
    with pytest.raises(ValueError, match="WEATHER_BACKEND"):
        create_app(replace(Settings(), backend="invalid"))
    with pytest.raises(ValueError, match="DATABASE_URL"):
        create_app(replace(Settings(), backend="postgres", database_url=""))

    ready = asyncio.Event()

    async def worker(client, config, state):
        assert config.backend == "postgres"
        await ready.wait()
        state.broker_ready = True
        await asyncio.Future()

    monkeypatch.setattr("fetcher.postgres_worker.run_worker", worker)

    async def check():
        config = replace(Settings(), backend="postgres", database_url="postgres://localhost/test",
                         rabbitmq_url="unused-invalid-url")
        app = create_app(config)
        async with app.router.lifespan_context(app):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
                assert (await client.get("/health")).status_code == 503
                ready.set()
                await asyncio.sleep(0)
                assert (await client.get("/health")).status_code == 200
                app.state.broker_ready = False
                assert (await client.get("/health")).status_code == 503
    asyncio.run(check())
