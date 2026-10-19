"""PGMQ request consumer; provider calls run outside database transactions."""
import asyncio
import json
import logging
from datetime import datetime, timezone
from uuid import UUID

import asyncpg

from .jobs import execute_job

logger = logging.getLogger("uvicorn.error")


class DeliveryLost(Exception):
    pass


async def claim_request(pool):
    return await pool.fetchrow("SELECT msg_id, read_ct, message FROM pgmq.read('weather_requests', 30, 1)")


async def lock_delivery(connection, message):
    # PGMQ increments read_ct on redelivery. Lock before checking ownership so
    # a stale worker cannot extend or acknowledge a newer delivery attempt.
    owned = await connection.fetchval("""
SELECT 1 FROM pgmq.q_weather_requests
WHERE msg_id=$1 AND read_ct=$2 AND vt>clock_timestamp()
FOR UPDATE
""", message["msg_id"], message["read_ct"])
    if owned is None:
        raise DeliveryLost("PGMQ delivery is no longer owned by this worker")


async def extend_visibility(pool, message):
    async with pool.acquire() as connection:
        async with connection.transaction():
            await lock_delivery(connection, message)
            await connection.execute("SELECT pgmq.set_vt('weather_requests', $1::bigint, 30)", message["msg_id"])


async def keep_visible(pool, message):
    while True:
        await asyncio.sleep(10)
        await extend_visibility(pool, message)


async def finish_request(pool, message, response):
    async with pool.acquire() as connection:
        async with connection.transaction():
            await lock_delivery(connection, message)
            if response is not None:
                body = json.dumps(response, allow_nan=False)
                if len(body.encode()) > 512 * 1024:
                    raise ValueError("Oversized weather response")
                await connection.execute("SELECT pgmq.send('weather_responses', $1::jsonb)", body)
            if not await connection.fetchval("SELECT pgmq.delete('weather_requests', $1::bigint)", message["msg_id"]):
                raise DeliveryLost("PGMQ request could not be acknowledged")


async def process_request(pool, message, client, config):
    try:
        if len(message["message"].encode()) > 64 * 1024:
            raise ValueError("Oversized request")
        job = json.loads(message["message"])
        UUID(job["request_id"])
        expires = datetime.fromisoformat(job["expires_at"])
        if expires.tzinfo is None or expires.utcoffset().total_seconds() != 0:
            raise ValueError("Expected UTC deadline")
    except (ValueError, KeyError, TypeError, AttributeError):
        await finish_request(pool, message, None)
        logger.warning("Rejected malformed PGMQ weather request")
        return
    if expires <= datetime.now(timezone.utc):
        await finish_request(pool, message, None)
        logger.info("Discarded expired PGMQ request %s", job["request_id"])
        return

    work = asyncio.create_task(execute_job(job, client, config))
    heartbeat = asyncio.create_task(keep_visible(pool, message))
    try:
        done, _ = await asyncio.wait((work, heartbeat), return_when=asyncio.FIRST_COMPLETED)
        if heartbeat in done:
            await heartbeat
        response = await work
        await finish_request(pool, message, response)
        if response["status"] == "failed":
            logger.warning("Weather job %s failed: %s", job["request_id"], response["error"]["code"])
        else:
            logger.info("Weather job %s completed backend=postgres", job["request_id"])
    finally:
        work.cancel()
        heartbeat.cancel()
        await asyncio.gather(work, heartbeat, return_exceptions=True)


async def run_worker(client, config, state):
    delay = 1
    while True:
        pool = None
        try:
            pool = await asyncpg.create_pool(
                config.database_url, min_size=1, max_size=2, timeout=5,
                command_timeout=5, server_settings={"timezone": "UTC"})
            while True:
                message = await claim_request(pool)
                state.broker_ready = True
                delay = 1
                if message is None:
                    await asyncio.sleep(1)
                else:
                    await process_request(pool, message, client, config)
        except asyncio.CancelledError:
            raise
        except Exception:
            # Connection exceptions can contain credentials; do not log them.
            logger.warning("PGMQ worker interrupted; reconnecting in %s seconds", delay)
        finally:
            state.broker_ready = False
            if pool is not None:
                try:
                    await asyncio.wait_for(pool.close(), 5)
                except (Exception, asyncio.CancelledError):
                    pool.terminate()
        await asyncio.sleep(delay)
        delay = min(delay * 2, 30)
