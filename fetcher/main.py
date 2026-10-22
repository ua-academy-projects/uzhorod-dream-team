"""Fetcher: takes weather requests from the queue and puts the answers back.

The queue is RabbitMQ (app_mode rabbitmq) or pgmq queues in PostgreSQL (app_mode postgres).
"""

import logging
import os
import sys
from pathlib import Path
from typing import Callable

import pika
from dotenv import load_dotenv

import config
from messages import (
    QUEUE_ARGUMENTS,
    REQUESTS_QUEUE,
    REQUESTS_QUEUE_ARGUMENTS,
    RESPONSES_QUEUE,
    InvalidMessage,
    build_response,
    parse_request,
)
from weather import fetch_current_temperature

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
# pika logs every connection step; only its warnings and errors are needed.
logging.getLogger("pika").setLevel(logging.WARNING)
logger = logging.getLogger("fetcher")

# Each queue entry gives up after this many attempts (x-delivery-limit in RabbitMQ).
MAX_ATTEMPTS = 5


def run_rabbitmq(amqp_url: str, fetch: Callable[[], dict]) -> None:
    """Handle requests from the RabbitMQ queue weather.requests until the connection breaks."""

    def on_request(channel, method, properties, body: bytes) -> None:
        """Handle one request: fetch the weather, publish the response, then ack the request."""
        try:
            request_id = parse_request(body)
        except InvalidMessage as error:
            logger.error("Некоректний запит відкинуто: %s", error)
            # requeue=False: RabbitMQ removes it, because repeating a broken message will not help.
            channel.basic_reject(delivery_tag=method.delivery_tag, requeue=False)
            return

        response = build_response(request_id, fetch)

        # The channel is in confirm mode, so basic_publish waits until RabbitMQ has
        # stored the response, and raises an error if it has not. mandatory=True:
        # an error also if the responses queue does not exist.
        channel.basic_publish(
            exchange="",
            routing_key=RESPONSES_QUEUE,
            body=response,
            properties=pika.BasicProperties(
                content_type="application/json",
                delivery_mode=pika.DeliveryMode.Persistent,
            ),
            mandatory=True,
        )
        # Only now the request is done. If Fetcher stops before this line,
        # RabbitMQ gives the request again (to this or the restarted Fetcher).
        channel.basic_ack(delivery_tag=method.delivery_tag)
        logger.info("Відповідь на запит %s надіслано", request_id)

    connection = pika.BlockingConnection(pika.URLParameters(amqp_url))
    channel = connection.channel()
    # Publisher confirms: RabbitMQ confirms every published message.
    channel.confirm_delivery()

    # The queue is created if it does not exist yet; durable: it survives a RabbitMQ restart.
    channel.queue_declare(REQUESTS_QUEUE, durable=True, arguments=REQUESTS_QUEUE_ARGUMENTS)
    channel.queue_declare(RESPONSES_QUEUE, durable=True, arguments=QUEUE_ARGUMENTS)

    # Take one request at a time: the next one comes only after ack of the previous one.
    channel.basic_qos(prefetch_count=1)
    channel.basic_consume(REQUESTS_QUEUE, on_request)

    logger.info("Чекаю запити в черзі %s", REQUESTS_QUEUE)
    # Runs until the connection breaks. Then the program exits with an error,
    # and Docker starts the container again (docker run --restart unless-stopped).
    channel.start_consuming()


def main() -> None:
    # Explicitly load the .env file that sits next to this file.
    load_dotenv(Path(__file__).parent / ".env")
    env = os.environ

    try:
        mode = config.parse_mode(env)
        city = config.require(env, "CITY_NAME")
        latitude = float(config.require(env, "CITY_LATITUDE"))
        longitude = float(config.require(env, "CITY_LONGITUDE"))
        timeout = config.positive_float(env, "OPEN_METEO_TIMEOUT_SECONDS")
        if mode == config.MODE_POSTGRES:
            import pgqueue  # psycopg is needed only in this mode

            lease_seconds = config.positive_int(env, "QUEUE_LEASE_SECONDS")
            config.check_lease(lease_seconds, timeout)
            settings = pgqueue.QueueSettings(
                # postgresql://role:password@host:port/database?sslmode=require
                database_url=config.require(env, "DATABASE_URL"),
                poll_seconds=config.positive_int(env, "QUEUE_POLL_INTERVAL_SECONDS"),
                lease_seconds=lease_seconds,
                max_attempts=MAX_ATTEMPTS,
            )
        else:
            # amqp://user:password@host:port/vhost
            amqp_url = config.require(env, "AMQP_URL")
    except (config.ConfigError, ValueError) as error:
        logger.error("Неправильні налаштування: %s", error)
        sys.exit(2)

    def fetch() -> dict:
        return fetch_current_temperature(city, latitude, longitude, timeout)

    logger.info("Режим %s", mode)
    if mode == config.MODE_POSTGRES:
        pgqueue.run(settings, fetch)
    else:
        run_rabbitmq(amqp_url, fetch)


if __name__ == "__main__":
    main()
