# DataFetcher

This directory contains the price collection applications and web UI, PostgreSQL initialization SQL, and the Docker Compose configuration.

## Services

| Service | Implementation | Role |
| --- | --- | --- |
| `fetcher` | Go | Polls price sources, serves the latest values, and processes collection tasks |
| `history` | Go | Periodically requests Fetcher, stores records, and provides an HTTP API |
| `ui` | FastAPI | Displays data and charts and stores user preferences |
| `postgres` | PostgreSQL 16 | Stores history, tasks, and preferences; provides PGMQ and HSTORE as needed |
| `rabbitmq`, `redis` | RabbitMQ, Redis | Request broker and preference cache for `hybrid` mode |

## Backend modes

`APP_BACKEND` must be the same for all three applications.

| Mode | Queue between History and Fetcher | UI preferences | Required services |
| --- | --- | --- | --- |
| `hybrid` | RabbitMQ; a PostgreSQL queue is available as a Fetcher fallback | PostgreSQL is the source of truth; Redis is the cache | PostgreSQL, RabbitMQ, Redis |
| `postgres` | PGMQ in PostgreSQL | HSTORE in PostgreSQL | PostgreSQL |

In `postgres` mode, the applications do not connect to RabbitMQ or Redis. See the [backend modes guide](../docs/BROKER_MODE.md) for details.

## Docker Compose

You need Docker Compose. Create a local configuration from the template and set your own passwords:

```powershell
Copy-Item .env.example .env
```

Set `APP_BACKEND=hybrid` or `APP_BACKEND=postgres`, validate the configuration, and start the services:

```sh
docker compose config
docker compose up --build -d
docker compose ps
docker compose logs -f ui history fetcher postgres
```

UI: [http://localhost:8000](http://localhost:8000). The History API is published on `http://localhost:8002`, and Fetcher on `http://localhost:8001`.

Stop the services while keeping volumes with `docker compose down`. The command `docker compose down -v` also deletes PostgreSQL, Redis, and RabbitMQ data.

The PostgreSQL image `ghcr.io/pgmq/pg16-pgmq:v1.10.0` includes the PGMQ files. `CREATE EXTENSION pgmq` registers the extension in a database; it does not install the extension files. The image also provides HSTORE.

## Vagrant

From the repository root, copy the Vagrant configuration template:

```powershell
Copy-Item DataFetcher\env_vagrant_example DataFetcher\.env
```

Set your passwords and configure the network bridge in the root `Vagrantfile`, then run `vagrant up`. The deployment creates five VMs; PostgreSQL, RabbitMQ, and Redis run together on the `postgres` VM. After changing `.env`, reprovision the VMs whose containers need the updated values:

```sh
vagrant provision postgres
vagrant provision fetcher
vagrant provision history
vagrant provision ui
```

See the [Vagrant guide](../docs/VAGRANT_BROKER_MODE.md) for detailed instructions.

## Configuration

Templates: [`.env.example`](.env.example) for Compose and [`env_vagrant_example`](env_vagrant_example) for Vagrant. Main variables:

- `APP_BACKEND` — `hybrid` or `postgres`.
- `SOURCES` — comma-separated `name=URL` pairs.
- `HISTORY_INTERVAL_SECONDS` — collection interval in seconds (10 seconds in the templates).
- `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` — History/UI connection settings.
- `FETCHER_POSTGRES_HOST`, `FETCHER_POSTGRES_PORT`, `FETCHER_POSTGRES_DB`, `FETCHER_POSTGRES_USER`, `FETCHER_POSTGRES_PASSWORD` — Fetcher's queue credentials.
- `RABBITMQ_URL`, `REDIS_URL` — used in `hybrid` mode.
- `HISTORY_SERVICE_URL` — History address used by UI; `COOKIE_SECURE` controls secure cookies for HTTPS.

Do not commit `.env`; it contains passwords.

## Health checks and database inspection

```sh
docker compose ps
docker compose logs --tail 100 postgres history fetcher
```

Check installed extensions with `SELECT extname FROM pg_extension WHERE extname IN ('pgmq', 'hstore');`. Check queues with `SELECT * FROM pgmq.list_queues();`. In `postgres` mode, completed tasks are in `fetcher_tasks`, active messages are in `pgmq.q_fetcher_tasks`, and price records are in `history`.

## Development

Run the Go service tests:

```sh
cd fetcher && go test ./...
cd ../history && go test ./...
```

Run UI tests (install packages from `ui/requirements-dev.txt` first):

```sh
cd ui
APP_BACKEND=postgres python -m pytest -q
```
