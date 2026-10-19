"""One RabbitMQ worker; all AMQP operations run on the asyncio event loop."""
import asyncio
import json
import logging
from dataclasses import replace
from datetime import datetime, timezone
from uuid import UUID

from fastapi import HTTPException

from .provider import number, fetch_current, fetch_temperature_range, validate_range

logger = logging.getLogger("uvicorn.error")


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


async def handle_message(message, publish_response, client, config):
    try:
        if len(message.body) > 64 * 1024:
            raise ValueError("Oversized request")
        job = json.loads(message.body)
        UUID(job["request_id"])
        if message.correlation_id != job["request_id"] or message.type != job.get("type"):
            raise ValueError("AMQP metadata mismatch")
    except (ValueError, KeyError, TypeError, AttributeError):
        logger.warning("Rejected malformed weather request")
        await message.reject(requeue=False)
        return
    response = await execute_job(job, client, config)
    await publish_response(response)  # Raises unless broker confirmed routing and delivery.
    await message.ack()
    if response["status"] == "failed":
        logger.warning("Weather job %s failed: %s", job["request_id"], response["error"]["code"])
    else:
        logger.info("Weather job %s completed", job["request_id"])


async def run_worker(client, config, state):
    import aio_pika

    delay = 1
    while True:
        connection = None
        try:
            connection = await aio_pika.connect(config.rabbitmq_url, timeout=5, heartbeat=30)
            consume_channel = await connection.channel(publisher_confirms=False)
            publish_channel = await connection.channel(publisher_confirms=True, on_return_raises=True)
            await consume_channel.set_qos(prefetch_count=1)
            queue = await consume_channel.declare_queue("weather.requests", durable=True)
            await publish_channel.declare_queue("weather.responses", durable=True)

            async def publish_response(response):
                message = aio_pika.Message(
                    body=json.dumps(response, allow_nan=False).encode(), content_type="application/json",
                    delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
                    correlation_id=response["request_id"], message_id=response["request_id"], type=response["type"],
                )
                confirmation = await publish_channel.default_exchange.publish(
                    message, routing_key="weather.responses", mandatory=True, timeout=5)
                if confirmation is None or confirmation is False:
                    raise RuntimeError("Response was not confirmed")

            state.broker_ready = True
            delay = 1
            async with queue.iterator(no_ack=False) as messages:
                async for message in messages:
                    await handle_message(message, publish_response, client, config)
        except asyncio.CancelledError:
            raise
        except Exception:
            # Never log the connection exception: it can contain URL credentials.
            logger.warning("RabbitMQ worker interrupted; reconnecting in %s seconds", delay)
        finally:
            state.broker_ready = False
            if connection:
                try:
                    await asyncio.wait_for(connection.close(), 5)
                except (Exception, asyncio.CancelledError):
                    pass
        # Closing a failed connection requeues its unacked task, with a pause.
        await asyncio.sleep(delay)
        delay = min(delay * 2, 30)
