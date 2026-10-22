"""Messages between History and Fetcher in RabbitMQ (JSON)."""

import json
from typing import Callable

from weather import WeatherError

# Both services declare the queues with exactly the same settings,
# otherwise RabbitMQ refuses the connection (PRECONDITION_FAILED).
REQUESTS_QUEUE = "weather.requests"
RESPONSES_QUEUE = "weather.responses"
QUEUE_ARGUMENTS = {
    # Quorum queue: stored on disk and counts how many times a message was delivered.
    "x-queue-type": "quorum",
    # After 5 failed deliveries the message is removed, so it does not repeat forever.
    "x-delivery-limit": 5,
}
REQUESTS_QUEUE_ARGUMENTS = {
    **QUEUE_ARGUMENTS,
    # A request older than 5 minutes is not needed: History sends a new one every 5 minutes.
    "x-message-ttl": 5 * 60 * 1000,  # milliseconds
}


class InvalidMessage(Exception):
    """The message is not a correct request; repeating it will not help."""


def parse_request(body: bytes) -> str:
    """Return request_id from the request or raise InvalidMessage."""
    try:
        request = json.loads(body)
    except (ValueError, UnicodeDecodeError) as error:
        raise InvalidMessage(f"не JSON: {error}") from error

    if not isinstance(request, dict):
        raise InvalidMessage("очікувався JSON-об'єкт")
    request_id = request.get("request_id")
    if not isinstance(request_id, str) or not request_id:
        raise InvalidMessage("немає request_id")
    return request_id


def build_response(request_id: str, fetch: Callable[[], dict]) -> bytes:
    """Fetch the weather and return the response for History as JSON bytes.

    If the weather could not be fetched, the response says so ("ok": false)
    and contains no made-up data.
    """
    try:
        response = {"request_id": request_id, "ok": True, "record": fetch()}
    except WeatherError:
        response = {
            "request_id": request_id,
            "ok": False,
            "error": "Не вдалося отримати погоду з Open-Meteo",
        }
    return json.dumps(response, ensure_ascii=False).encode("utf-8")
