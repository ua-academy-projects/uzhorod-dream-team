from fastapi.testclient import TestClient

import main


def test_index():
    response = TestClient(main.app).get("/")
    assert response.status_code == 200
    assert "Data Monitor" in response.text


def test_api_history(monkeypatch):
    async def history(source="btc"):
        return {
            "data": [{"id": 1, "value": 12.3, "recorded_at": "2026-09-29T12:00:00Z"}]
        }

    monkeypatch.setattr(main.history_client, "history", history)
    response = TestClient(main.app).get("/api/history")
    assert response.status_code == 200
    assert response.json()["data"][0]["value"] == 12.3


def test_api_history_failure(monkeypatch):
    async def fail():
        raise RuntimeError("private backend details")

    monkeypatch.setattr(main.history_client, "history", fail)
    response = TestClient(main.app).get("/api/history")
    assert response.status_code == 503
    assert response.json() == {
        "error": "Unable to load historical data. Please try again later."
    }
