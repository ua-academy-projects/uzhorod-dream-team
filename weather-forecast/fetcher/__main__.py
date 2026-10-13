import uvicorn

from .config import settings

if __name__ == "__main__":
    if not settings.rabbitmq_url:
        raise SystemExit("RABBITMQ_URL is required to start the Fetcher worker")
    uvicorn.run("fetcher.app:app", host=settings.host, port=settings.port)
