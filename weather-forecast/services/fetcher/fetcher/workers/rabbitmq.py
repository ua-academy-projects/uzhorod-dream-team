"""RabbitMQ request consumer and confirmed response publisher."""
import asyncio
import json
import logging
from uuid import UUID

from .jobs import execute_job

logger = logging.getLogger("uvicorn.error")


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
