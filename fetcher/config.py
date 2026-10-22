"""Settings of Fetcher from environment variables, checked with clear errors."""

from collections.abc import Mapping

# Modes of the app (app_mode in weather-vm.yml, APP_MODE in .env).
MODE_RABBITMQ = "rabbitmq"  # queues in RabbitMQ
MODE_POSTGRES = "postgres"  # pgmq queues in PostgreSQL


class ConfigError(Exception):
    """A setting is missing or wrong; the message says which one and why."""


def require(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "")
    if not value:
        raise ConfigError(f"Змінна {name} не задана. Скопіюй .env.example у .env")
    return value


def parse_mode(env: Mapping[str, str]) -> str:
    value = env.get("APP_MODE", "")
    if value not in (MODE_RABBITMQ, MODE_POSTGRES):
        raise ConfigError(
            f"Змінна APP_MODE={value!r}: потрібно {MODE_RABBITMQ} або {MODE_POSTGRES}"
            " (app_mode у weather-vm.yml)"
        )
    return value


def positive_int(env: Mapping[str, str], name: str) -> int:
    value = require(env, name)
    if not value.isdigit() or int(value) <= 0:
        raise ConfigError(f"Змінна {name}={value!r}: потрібне ціле число більше за нуль")
    return int(value)


def positive_float(env: Mapping[str, str], name: str) -> float:
    value = require(env, name)
    try:
        number = float(value)
    except ValueError:
        number = 0.0
    if not number > 0:
        raise ConfigError(f"Змінна {name}={value!r}: потрібне число більше за нуль")
    return number


def min_lease_seconds(timeout_seconds: float) -> float:
    """The shortest lease that is still longer than one request to Open-Meteo.

    httpx applies the timeout to each phase of a request separately (connect, write,
    read, wait for a free connection), so one request may take up to 4 x timeout.
    10 seconds more are for the database (taking the request and writing the answer).
    """
    return 4 * timeout_seconds + 10


def check_lease(lease_seconds: int, timeout_seconds: float) -> None:
    minimum = min_lease_seconds(timeout_seconds)
    if lease_seconds < minimum:
        raise ConfigError(
            f"QUEUE_LEASE_SECONDS={lease_seconds}: оренда має бути щонайменше {minimum:g} с"
            " (4 × OPEN_METEO_TIMEOUT_SECONDS + 10 с запасу), інакше запит можуть"
            " перевидати, поки Fetcher ще чекає Open-Meteo"
        )
