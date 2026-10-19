import uvicorn

from .config import settings

if __name__ == "__main__":
    if settings.backend == "rabbitmq_redis" and not settings.rabbitmq_url:
        raise SystemExit("RABBITMQ_URL is required to start the Fetcher worker")
    if settings.backend == "postgres" and not settings.database_url:
        raise SystemExit("DATABASE_URL is required to start the PostgreSQL Fetcher worker")
    uvicorn.run("fetcher.app:app", host=settings.host, port=settings.port)
