"""The queue in PostgreSQL (app_mode postgres): queues of the extension pgmq.

Fetcher takes a request from the queue weather_requests with pgmq.read (the request is
hidden from others for lease_seconds), asks Open-Meteo and then, in one transaction,
removes the request (pgmq.delete) and sends the answer to weather_responses (pgmq.send).
The messages are the same JSON as in RabbitMQ (see messages.py).
"""

import logging
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Callable

import psycopg

from messages import InvalidMessage, build_response, parse_request

logger = logging.getLogger("fetcher")

# Names of the pgmq queues: like weather.requests and weather.responses in RabbitMQ.
REQUESTS_QUEUE = "weather_requests"
RESPONSES_QUEUE = "weather_responses"
# A request older than this is not needed: History makes a new one every 5 minutes.
# The same as x-message-ttl in RabbitMQ and requestTTL in History.
REQUEST_TTL = timedelta(minutes=5)
# Pause before the next attempt after an error of PostgreSQL.
RETRY_SECONDS = 5


@dataclass(frozen=True)
class QueueSettings:
    database_url: str
    poll_seconds: int  # how often to look into the queue when it is empty
    lease_seconds: int  # how long a taken request is hidden from others (vt of pgmq)
    max_attempts: int  # after this many reads the request is removed


@dataclass(frozen=True)
class Lease:
    """A request taken by this Fetcher with pgmq.read."""

    msg_id: int
    # read_ct of pgmq: how many times the request was taken, this time included.
    # It also marks the lease: when the request is taken again, read_ct grows.
    attempts: int
    enqueued_at: datetime
    body: str


# pgmq.read takes the oldest request that is visible, hides it for lease_seconds
# (FOR UPDATE SKIP LOCKED inside: two Fetchers never take the same request)
# and counts one more read. The statement runs on its own (autocommit), so the lease
# is stored at once: if Fetcher stops after this, the request is taken again when
# lease_seconds end.
CLAIM_SQL = """
    SELECT msg_id, read_ct, enqueued_at, message::text
    FROM pgmq.read(%(queue)s, %(lease_seconds)s, 1)
"""


def claim(conn: psycopg.Connection, lease_seconds: int) -> Lease | None:
    row = conn.execute(CLAIM_SQL, {"queue": REQUESTS_QUEUE, "lease_seconds": lease_seconds}).fetchone()
    return Lease(*row) if row else None


# Results of finish().
DONE = "done"  # the request is removed, the answer is sent
REMOVED = "removed"  # the request is removed without an answer
LEASE_LOST = "lease_lost"  # our lease is not valid any more: nothing was changed


def finish(conn: psycopg.Connection, lease: Lease, response: bytes | None) -> str:
    """Finish the request in ONE transaction: remove it and send the answer (if any).

    pgmq.delete removes a message by its id only, so first the lease is checked: the row
    is locked and its read_ct must still be ours. If the lease ended and the request was
    taken again (read_ct grew), or it is already removed, nothing is changed: an old
    Fetcher cannot finish a request that is not its own.
    If any statement fails, the transaction is rolled back: the request stays in the
    queue and is taken again when the lease ends.
    """
    with conn.transaction():
        row = conn.execute(
            "SELECT read_ct FROM pgmq.q_weather_requests WHERE msg_id = %s FOR UPDATE",
            (lease.msg_id,),
        ).fetchone()
        if row is None or row[0] != lease.attempts:
            return LEASE_LOST
        conn.execute("SELECT pgmq.delete(%s, %s::bigint)", (REQUESTS_QUEUE, lease.msg_id))
        if response is None:
            return REMOVED
        conn.execute("SELECT pgmq.send(%s, %s::jsonb)", (RESPONSES_QUEUE, response.decode("utf-8")))
    return DONE


# Decisions before the work (see what_to_do).
TOO_MANY_ATTEMPTS = "too_many_attempts"
EXPIRED = "expired"
PROCESS = "process"


def what_to_do(lease: Lease, now: datetime, max_attempts: int) -> str:
    """Should this request be handled? Like x-delivery-limit and x-message-ttl in RabbitMQ."""
    if lease.attempts > max_attempts:
        return TOO_MANY_ATTEMPTS
    if now - lease.enqueued_at > REQUEST_TTL:
        return EXPIRED
    return PROCESS


def handle_one(conn: psycopg.Connection, settings: QueueSettings, fetch: Callable[[], dict]) -> bool:
    """Handle one request. Returns False if there was no free request."""
    lease = claim(conn, settings.lease_seconds)
    if lease is None:
        return False

    decision = what_to_do(lease, datetime.now(timezone.utc), settings.max_attempts)
    if decision == TOO_MANY_ATTEMPTS:
        if finish(conn, lease, None) == REMOVED:
            logger.error(
                "Запит (повідомлення %d) видалено: %d спроб обробки не завершилися",
                lease.msg_id, settings.max_attempts,
            )
        return True
    if decision == EXPIRED:
        if finish(conn, lease, None) == REMOVED:
            logger.warning(
                "Запит (повідомлення %d) застарів (створено %s, старший за %s) — видалено без обробки",
                lease.msg_id, lease.enqueued_at.isoformat(), REQUEST_TTL,
            )
        return True

    try:
        request_id = parse_request(lease.body.encode("utf-8"))
    except InvalidMessage as error:
        # Repeating a broken request will not help: it is removed.
        if finish(conn, lease, None) == REMOVED:
            logger.error("Некоректний запит (повідомлення %d) відкинуто: %s", lease.msg_id, error)
        return True

    logger.info(
        "Взято запит %s (спроба %d з %d, оренда %d с)",
        request_id, lease.attempts, settings.max_attempts, settings.lease_seconds,
    )
    # On an error of Open-Meteo the answer says so ("ok": false), without made-up weather.
    response = build_response(request_id, fetch)

    if finish(conn, lease, response) == DONE:
        logger.info("Відповідь на запит %s надіслано в чергу pgmq %s", request_id, RESPONSES_QUEUE)
    else:
        logger.warning(
            "Оренду запиту %s втрачено (минуло понад %d с або запит уже завершено) —"
            " відповідь не надіслано",
            request_id, settings.lease_seconds,
        )
    return True


def run(settings: QueueSettings, fetch: Callable[[], dict]) -> None:
    """Handle requests from the queue weather_requests forever.

    When the queue has no free request, wait poll_seconds and look again: this is only
    a query to the queue, Open-Meteo is asked only for a request.
    """
    # The first connection is not retried: if it fails (wrong password, no access),
    # the program exits with the error and provisioning sees it.
    conn = psycopg.connect(settings.database_url, autocommit=True)
    logger.info(
        "Підключено до PostgreSQL; чекаю запити в черзі pgmq %s (перевірка кожні %d с)",
        REQUESTS_QUEUE, settings.poll_seconds,
    )
    while True:
        try:
            if conn.closed:
                conn = psycopg.connect(settings.database_url, autocommit=True)
                logger.info("Знову підключено до PostgreSQL")
            if not handle_one(conn, settings, fetch):
                time.sleep(settings.poll_seconds)
        except psycopg.Error as error:
            # The transaction of the request was rolled back: the request stays in the
            # queue and is taken again when its lease ends.
            logger.error("ПОМИЛКА PostgreSQL: %s — повтор через %d с", str(error).strip(), RETRY_SECONDS)
            time.sleep(RETRY_SECONDS)
