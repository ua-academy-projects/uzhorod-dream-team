# Backend modes

All applications read `APP_BACKEND`. Set the same value for Fetcher, History, and UI: `hybrid` or `postgres`. Any other value causes the application to stop with a configuration error.

| Mode | Task delivery | User preferences | External brokers |
| --- | --- | --- | --- |
| `hybrid` | RabbitMQ request/reply between History and Fetcher. A PostgreSQL queue is available as a Fetcher fallback | PostgreSQL is the source of truth; Redis is the cache | RabbitMQ and Redis |
| `postgres` | PGMQ in PostgreSQL | HSTORE in PostgreSQL | Not required |

History is always stored in PostgreSQL. Both modes use the `fetcher_tasks` table; in `postgres` mode it stores task status and results, while PGMQ stores messages for Fetcher. Creating a task and sending its PGMQ message happen in one PostgreSQL transaction.

## `hybrid` mode

1. History sends a request through RabbitMQ.
2. Fetcher receives it, calls the price APIs, and returns the result through RabbitMQ.
3. History stores the values in PostgreSQL.
4. UI reads and saves preferences through History/PostgreSQL and caches them in Redis.

If UI cannot read preferences from History, it may return an existing value from Redis. New changes are saved to PostgreSQL first, then update Redis.

## `postgres` mode

1. History creates a task and a PGMQ message in a PostgreSQL transaction.
2. Fetcher reads the message, calls the price APIs, and stores the task result.
3. History reads the completed task and stores the price history.
4. UI reads and saves preferences through History in a table that uses HSTORE.

PGMQ provides message visibility and redelivery. A processed task keeps its status and result in `fetcher_tasks`; the PGMQ message is acknowledged by deletion or archived depending on the processing result.

## PostgreSQL and PGMQ

PGMQ uses the PostgreSQL 16 image `ghcr.io/pgmq/pg16-pgmq:v1.10.0`. The image includes the server extension files; `CREATE EXTENSION pgmq` registers it in the selected database. The setup SQL creates the `fetcher_tasks` queue and the restricted `fetcher_worker` role.

HSTORE stores user preference maps in `user_preferences`. The session key is the primary key; records older than 30 days are treated as absent. UI cookies use the same lifetime.

## Run and switch modes

For Compose, copy `DataFetcher/.env.example` to `DataFetcher/.env`, set `APP_BACKEND`, and run:

```sh
cd DataFetcher
docker compose config
docker compose up --build -d
```

Compose starts RabbitMQ and Redis in `hybrid` mode. They are not application dependencies in `postgres` mode.

For Vagrant, change `APP_BACKEND` in `DataFetcher/.env` and reprovision `fetcher`, `history`, and `ui` to recreate their containers. PostgreSQL setup only needs to be reprovisioned when the server side needs PGMQ setup. See [Vagrant and backend modes](VAGRANT_BROKER_MODE.md).

## Inspect the setup

```sql
SELECT extname
FROM pg_extension
WHERE extname IN ('pgmq', 'hstore');

SELECT * FROM pgmq.list_queues();
```

In `postgres` mode, completed tasks are in `fetcher_tasks`, active messages are in `pgmq.q_fetcher_tasks`, archived messages are in `pgmq.a_fetcher_tasks`, and price records are in `history`.
