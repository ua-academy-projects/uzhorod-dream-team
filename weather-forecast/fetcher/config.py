import os
from dataclasses import dataclass

@dataclass(frozen=True)
class Settings:
    """Fetcher service settings."""
    rabbitmq_url: str = os.getenv("RABBITMQ_URL", "")
    host: str = os.getenv("FETCHER_HOST", "127.0.0.1")
    port: int = int(os.getenv("FETCHER_PORT", "8001"))

    # City coordinates (Uzhhorod by default)
    city_name: str = os.getenv("CITY_NAME", "Uzhhorod")
    city_lat: float = float(os.getenv("CITY_LATITUDE", "48.6167"))
    city_lon: float = float(os.getenv("CITY_LONGITUDE", "22.3"))

    # Open-Meteo API request settings
    open_meteo_url: str = os.getenv("OPEN_METEO_URL", "https://api.open-meteo.com/v1/forecast")
    timeout_seconds: float = float(os.getenv("OPEN_METEO_TIMEOUT_SECONDS", "10.0"))

settings = Settings()
