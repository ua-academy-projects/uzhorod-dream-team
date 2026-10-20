from datetime import datetime

import httpx
from pydantic import BaseModel


class HistoryRecord(BaseModel):
    id: int
    source: str
    value: float
    recorded_at: datetime


class HistoryResponse(BaseModel):
    data: list[HistoryRecord]


class SourcesResponse(BaseModel):
    data: list[str]


class HistoryClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    async def history(self, source: str = "btc", limit: int = 100) -> dict:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(
                f"{self.base_url}/history",
                params={"source": source, "limit": limit},
            )
            response.raise_for_status()
            result = HistoryResponse.model_validate(response.json())
            return result.model_dump(mode="json")

    async def sources(self) -> dict:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(f"{self.base_url}/sources")
            response.raise_for_status()
            result = SourcesResponse.model_validate(response.json())
            return result.model_dump(mode="json")

    async def preferences(self, session_id: str) -> dict | None:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(
                f"{self.base_url}/preferences/{session_id}"
            )

            if response.status_code == 404:
                return None

            response.raise_for_status()
            return response.json()["preferences"]

    async def save_preferences(
        self,
        session_id: str,
        preferences: dict,
    ) -> dict:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.put(
                f"{self.base_url}/preferences/{session_id}",
                json={"preferences": preferences},
            )
            response.raise_for_status()
            return response.json()["preferences"]