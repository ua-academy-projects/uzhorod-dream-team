# Architecture

## Components

```
┌────────────┐  POST /api/weather/fetch   ┌────────────────────────┐   weather.fetch.requests   ┌─────────────────┐  HTTPS   ┌────────────┐
│ Scheduler  │ ─────────────────────────▶ │ History service        │ ────────▶ ┌──────────┐ ───▶ │ Fetcher service │ ───────▶ │ Open-Meteo │
│ node-cron  │                            │ (Express, :3001)       │           │ RabbitMQ │      │ (Go, worker)    │          └────────────┘
└────────────┘                            │                        │ ◀──────── └──────────┘ ◀─── └─────────────────┘
┌────────────┐  GET /api/weather/*        │  Sequelize             │   weather.fetch.replies
│ React UI   │ ─────────────────────────▶ └───────────┬────────────┘
│ Vite       │  /api/preferences                      ▼                ┌───────┐
└────────────┘                                 ┌────────────┐          │ Redis │ ◀── History (UI preferences)
                                               │ PostgreSQL │          └───────┘
                                               └────────────┘
```

| Component | Location | Responsibility | Depends on |
|---|---|---|---|
| **Fetcher service** | `fetcher/` | Go worker (compiled binary, no HTTP API). Consumes fetch requests from RabbitMQ, calls Open-Meteo and publishes normalized observations back through a queue. Stateless and has no database. | RabbitMQ, Open-Meteo |
| **History service** | `history/` (port 3001) | HTTP API. Asks the Fetcher for data over RabbitMQ (`history/src/broker.js`, `history/src/fetcherClient.js`), stores it through Sequelize, and serves historical data. Keeps UI preferences in Redis. | RabbitMQ, PostgreSQL, Redis |
| **RabbitMQ** | DB VM / `docker-compose.yml` | Two durable queues: `weather.fetch.requests` and `weather.fetch.replies`. | — |
| **Scheduler** | `scheduler/` | Separate process that calls `POST /api/weather/fetch` on a cron schedule (hourly by default). | History service URL only |
| **Frontend** | `frontend/` | React UI: latest reading, range selector, charts and table. | History service API |
| **Database** | `docker-compose.yml` | Generic PostgreSQL 16 container. The app uses its own database (`weather`) inside it and creates that database if it's missing. | — |

Each component knows only the component next to it. The scheduler doesn't know about the weather API. The Fetcher
doesn't know about the database or the History service: it only sees the queues. There is no direct HTTP between the
History service and the Fetcher. The frontend only talks to the History service.

## Request flow

```mermaid
sequenceDiagram
    participant S as Scheduler (cron)
    participant H as History service
    participant Q as RabbitMQ
    participant F as Fetcher service
    participant O as Open-Meteo
    participant DB as PostgreSQL
    participant UI as React UI

    S->>H: POST /api/weather/fetch
    H->>Q: {type: current, location} → weather.fetch.requests (replyTo, correlationId)
    Q->>F: deliver request
    F->>O: GET /v1/forecast?current=...
    O-->>F: JSON
    F->>Q: {ok: true, data: observation} → weather.fetch.replies (same correlationId)
    F->>Q: ack request
    Q->>H: deliver reply
    H->>DB: INSERT ... ON CONFLICT (location_name, observed_at) DO UPDATE
    H-->>S: 201 + saved observation

    UI->>H: GET /api/weather/latest, GET /api/weather/history?from&to
    H->>DB: SELECT ...
    DB-->>H: rows
    H-->>UI: JSON
```

## Startup catch-up

On start the History service (in the background, with retries) looks up the newest stored `observedAt`, asks the
Fetcher (a `history` request with `days=N`) for the gap (N = gap in days rounded up, at most 92; 30 if the table is empty)
and inserts the rows with `ON CONFLICT DO NOTHING`. The Fetcher stays stateless and does not know about the gap.

## Fetcher messages (RabbitMQ)

The Fetcher is stateless: the caller (the History service) sends the location with every request. Request/reply over
two durable queues in the `weather` vhost:

- the History service publishes a request to `weather.fetch.requests` with `replyTo = weather.fetch.replies`, a fresh
  `correlationId` and `expiration` = its 20 s timeout (a request nobody waits for any more expires in the queue);
- the Fetcher consumes it (prefetch 4), calls Open-Meteo, publishes the reply to `replyTo` with the same
  `correlationId`, and only then acks the request (a crash in between makes RabbitMQ redeliver it);
- the History service matches the reply to the waiting call by `correlationId`; replies nobody waits for are logged and dropped.

| Request | Reply `data` |
|---|---|
| `{ "type": "current", "location": { "name", "latitude", "longitude" } }` | one observation |
| `{ "type": "history", "location": {...}, "days": 1..92 }` (default 7) | hourly observations for the last `days` days, up to now |

Errors look like `{ "ok": false, "error": "message", "kind": "bad_request" | "upstream" | "internal" }`;
success is `{ "ok": true, "data": ... }`.

An observation is a plain object:
`{ locationName, latitude, longitude, observedAt, temperature, apparentTemperature, humidity, precipitation, windSpeed, windDirection, weatherCode, source }`.

Inside the History service, `history/src/fetcherClient.js` wraps these calls as `fetchCurrent(location)` and
`fetchRecentHistory(location, days)`. It turns `observedAt` back into a `Date` and throws `FetcherError` if the broker
is down, no reply arrives in time, or the Fetcher replies with an error (the History service then answers with 502).

The Fetcher does not reconnect by itself: when the connection to RabbitMQ is lost it exits with an error and systemd
restarts it. The History service reconnects in the background, with backoff.

To run the Fetcher without the server or database: `cd fetcher && go run ./cmd/fetcher --once` (add `--history 2` for hourly data).

## Data model

Table `weather_observations` (created by `sequelize.sync()` at startup):

| Column | Type | Notes |
|---|---|---|
| id | serial PK | |
| location_name, latitude, longitude | text / double | |
| observed_at | timestamptz | time the data applies to (UTC) |
| temperature, apparent_temperature | real | °C |
| humidity | real | % |
| precipitation | real | mm |
| wind_speed | real | km/h |
| wind_direction | real | degrees |
| weather_code | integer | WMO code; the API also returns `conditions` text |
| source | enum `current` / `historical` | scheduled fetch or backfill |
| created_at, updated_at | timestamptz | |

A unique index on `(location_name, observed_at)` makes writes idempotent:

- **fetch** does an upsert, so repeating a fetch in the same 15-minute slot refreshes the row instead of adding a new one;
- **backfill** inserts only missing hours and never overwrites rows that already exist.

## HTTP API

| Method | Path | Description |
|---|---|---|
| GET | `/api/health` | `{ status, database, cache, broker }` |
| GET / PUT | `/api/preferences` | UI preferences of this browser (`{ theme }`), stored in Redis; the browser is identified by the `uid` cookie. |
| POST | `/api/weather/fetch` | Fetch current weather and store it. Returns the stored observation (201). |
| POST | `/api/weather/backfill` | Body `{ "days": 1..92 }` (default 7). Returns `{ days, fetched, inserted }`. |
| GET | `/api/weather/latest` | Latest observation, or 404 if there are none yet. |
| GET | `/api/weather/history?from=&to=&limit=` | Observations in the range, oldest first. `from`/`to` are ISO dates and default to the last 7 days. `limit` is capped at 5000. |

If `TRIGGER_TOKEN` is set in `history/.env`, both POST endpoints require an `X-Trigger-Token` header with that value.
Errors look like `{ "error": "message" }`: 400 for invalid input, 502 if the Fetcher service or the weather API fails, 500 for anything else.

## Deliberate simplifications (demo scope)

- The table is created with `sequelize.sync()`. There's no migration tooling.
- The app tracks a single location, set in `history/.env`. The schema already stores the location, so adding more would be simple.
- There's no authentication beyond the optional trigger token.
- For local development PostgreSQL and RabbitMQ run in Docker; the services run locally.
- The Fetcher has no network API at all; only clients with RabbitMQ credentials can send it requests.
