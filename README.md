# Weather History Demo

A small demo app that fetches weather data from [Open-Meteo](https://open-meteo.com/) on a schedule, stores it in
PostgreSQL, and shows the current reading and history in a React UI with charts and a table.

```
Scheduler ──POST /api/weather/fetch──▶ History service ──▶ RabbitMQ ──▶ Fetcher service ──▶ Open-Meteo
                                             │          ◀── (reply queue) ◀──┘
React UI ◀──── GET /api/weather/* ───────────┤
                                             ├──▶ PostgreSQL
                                             └──▶ Redis (UI preferences)
```

- [docs/architecture.md](docs/architecture.md): components, request flow, data model and HTTP API
- [docs/weather-api.md](docs/weather-api.md): the chosen weather API and its free-tier limits
- [docs/infrastructure.md](docs/infrastructure.md): the Vagrant VMs, their Docker containers, provisioning scripts and useful commands

## Tech stack

| Part | Tech |
|---|---|
| Fetcher service | Go (compiled), amqp091-go |
| History service | Node.js, Express, Sequelize, pg, amqplib, redis |
| Scheduler | Node.js, node-cron (a system crontab works too, see below) |
| Frontend | React, Vite, Recharts |
| Database, cache, queue | PostgreSQL 16, Redis, RabbitMQ (Docker locally and on the DB VM under Vagrant) |

## Project structure

```
.
├── fetcher/            # Fetcher service in Go (RabbitMQ worker, no HTTP API): talks to Open-Meteo
│   ├── cmd/fetcher/    #   main.go: entry point (queue worker, or --once)
│   ├── Dockerfile      #   image for the Vagrant VM (each service folder has one)
│   └── internal/       #   config, openmeteo (client + mapper), worker (queue consumer); *_test.go next to the code
├── history/            # History service (Express API, port 3001)
│   ├── src/            #   routes, service, Sequelize model, catch-up logic, broker.js + fetcherClient.js (RabbitMQ client for the Fetcher)
│   └── test/
├── scheduler/          # cron process that calls POST /api/weather/fetch
├── frontend/           # React UI
├── docs/
└── docker-compose.yml  # generic, reusable PostgreSQL container + RabbitMQ
```

This is an npm workspaces monorepo for the Node.js parts: one `npm install` at the root installs them. The Fetcher is a separate Go module.

## Prerequisites

- Node.js 20 or later (tested with 24)
- Go 1.22 or later (for the Fetcher, see [Go for beginners](#go-for-beginners-fetcher))
- Docker with `docker-compose` (or `docker compose`)

## Setup

```bash
# 1. Environment files (the defaults work out of the box)
cp .env.example .env
cp fetcher/.env.example fetcher/.env
cp history/.env.example history/.env
cp scheduler/.env.example scheduler/.env
cp frontend/.env.example frontend/.env

# 2. Start PostgreSQL and RabbitMQ (Redis: any local instance on :6379)
npm run db:up            # = docker-compose up -d

# 3. Install dependencies for all workspaces
npm install
```

The PostgreSQL container (`postgres`) is generic, so other projects can use it too. The History service creates the
`weather` database and its table on first start if they don't exist.

## Run

The services are independent and each has its own command. Start them in separate terminals, in any order:

```bash
npm run dev:fetcher    # Fetcher (Go): consumes requests from RabbitMQ
npm run dev:history    # History service on http://localhost:3001, together with the scheduler
npm run dev:frontend   # UI on http://localhost:5173
```

The History service reconnects to RabbitMQ and retries its startup catch-up until the Fetcher answers, so the order doesn't matter.
`npm run dev` starts all three at once in one terminal (convenient for local development).

To run the History service without the scheduler: `npm run dev -w history`. The scheduler alone: `npm start -w scheduler`.

Open the UI at http://localhost:5173. If that port is busy, Vite picks the next free one and prints it.

## Production-like run

Build everything on your machine, copy the results to the server and start each service in its own terminal
(or under a process manager). Nothing here uses `concurrently`, so `npm ci --omit=dev` is enough on the server.

```bash
# 1. On your machine: build
npm run build:fetcher     # fetcher/bin/fetcher (single binary)
npm run build:frontend    # frontend/dist (static files); set VITE_API_URL in frontend/.env first (see below)

# 2. On the server: start, one terminal per service
npm run start:fetcher     # ./fetcher/bin/fetcher (reads fetcher/.env from the fetcher/ folder)
npm run start:history     # History service, :3001 (NODE_ENV=production)
npm run start:scheduler   # scheduler (can share a machine with History)
npm run start:frontend    # serves frontend/dist on :4173 (npx serve); nginx works too
```

What to copy where:

| Service | Files | Setup on the server |
|---|---|---|
| Fetcher | `fetcher/bin/fetcher`, `fetcher/.env` | nothing (no Go needed) |
| History + scheduler | `history/`, `scheduler/` (each with its own `package-lock.json`) and their `.env` files | `npm ci --omit=dev` in each folder |
| Frontend | `frontend/dist/` | any static web server |

Notes:
- The static frontend has no dev proxy, so build it with `VITE_API_URL=http://<History address>:3001` in `frontend/.env`
  (the value is baked into the build), or put a web server in front that proxies `/api` to History.
- `start:frontend` downloads the small `serve` package through `npx` on first use (needs internet access).
- Set `AMQP_URL` in `history/.env` and `fetcher/.env` (same broker) and `HISTORY_SERVICE_URL` in `scheduler/.env` to the real addresses.
- The Fetcher has no network API; only clients with RabbitMQ credentials can send it requests.

## Run on Vagrant VMs (Docker)

Four VMs, every service in its own Docker container. Provisioning installs Docker, writes the env/config files with
the secrets from the root `.env` into `/etc/weather/`, builds the images on the VM and starts the containers with
`--restart unless-stopped`, so the Docker daemon starts them again after a reboot. Details, flags and image
optimizations: [docs/infrastructure.md](docs/infrastructure.md).

```bash
cp .env.example .env   # set POSTGRES_PASSWORD, REDIS_PASSWORD, RABBITMQ_PASSWORD, BRIDGE_IF
cp ~/.ssh/id_ed25519.pub .   # your SSH public key, added to authorized_keys on every VM
vagrant up             # weather-postgres-db .10, weather-fetcher .11, weather-history .12, weather-frontend .13
```

| VM | Containers |
|---|---|
| `weather-postgres-db` | `postgres`, `redis`, `rabbitmq` |
| `weather-fetcher` | `fetcher` |
| `weather-history` | `history`, `scheduler` |
| `weather-frontend` | `frontend` (nginx: UI + `/api` proxy) |

Check and open:

```bash
vagrant ssh <vm> -c "docker ps"               # every container Up; postgres, redis, rabbitmq, frontend (healthy)
curl http://192.168.56.12:3001/api/health     # {"status":"ok","database":"up","cache":"up","broker":"up"}
vagrant reload weather-frontend --provision   # prints "weather-frontend LAN URL: http://<ip>:4173"
```

The UI is at http://192.168.56.13:4173 from the host, or at the printed LAN URL from other devices; the RabbitMQ
management UI at http://192.168.56.10:15672 (`weather` / `RABBITMQ_PASSWORD`).

After a code or `.env` change: `vagrant provision <vm>` rebuilds the images and recreates that VM's containers
(each VM mounts only its own service folders, read-only).
Data stays in the named volumes `pgdata`, `redisdata` and `rabbitmqdata`.

Logs of all VMs (system and containers) are pulled every 15 minutes onto `weather-history` as zstd archives and
kept for 7 days (`LOG_RETENTION_DAYS`): `sudo journalctl -D /var/log/journal/remote` there, details in
[docs/infrastructure.md#logs](docs/infrastructure.md#logs).

## Configuration

Each part reads its own `.env` file (see the `.env.example` files):

| File | Variable | Default | Purpose |
|---|---|---|---|
| `.env` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_PORT` | `postgres` / `postgres` / `weather` / `5432` | PostgreSQL container |
| `fetcher/.env` (read at start from the `fetcher/` folder; real environment variables override it) | `AMQP_URL` | `amqp://guest:guest@localhost:5672/` | RabbitMQ with the request/reply queues |
| | `OPEN_METEO_BASE_URL` | `https://api.open-meteo.com/v1/forecast` | Weather API |
| | `LOCATION_NAME`, `LATITUDE`, `LONGITUDE` | Berlin, 52.52, 13.41 | Default location, used only by `--once` |
| `history/.env` | `PORT` | `3001` | History service port |
| | `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/weather` | DB connection |
| | `LOCATION_NAME`, `LATITUDE`, `LONGITUDE` | Berlin, 52.52, 13.41 | Location to track (sent to the Fetcher with every request) |
| | `CATCH_UP_ON_START` | `true` | Fetch missed hourly history when the service starts |
| | `INITIAL_BACKFILL_DAYS` | `30` | Days to load when the database is empty |
| | `AMQP_URL` | `amqp://guest:guest@localhost:5672` | RabbitMQ, to reach the Fetcher |
| | `REDIS_URL` | `redis://localhost:6379` | Redis for UI preferences |
| | `TRIGGER_TOKEN` | empty (off) | If set, POST endpoints require an `X-Trigger-Token` header |
| `scheduler/.env` | `HISTORY_SERVICE_URL` | `http://localhost:3001` | Where to send the trigger |
| | `CRON_SCHEDULE` | `0 * * * *` (hourly) | For example `*/30 * * * *` for every 30 minutes |
| | `TRIGGER_TOKEN` | empty | Must match the History value |
| `frontend/.env` | `VITE_API_URL` | empty (uses the Vite proxy) | History service base URL |
| | `VITE_PROXY_TARGET` | `http://localhost:3001` | Where the dev proxy sends `/api` |

## Using system cron instead of the Node scheduler

The scheduler only calls one endpoint, so a crontab entry (`crontab -e`) does the same job:

```cron
0 * * * * curl -fsS -X POST http://localhost:3001/api/weather/fetch >> /tmp/weather-fetch.log 2>&1
```

## Useful commands

```bash
npm test                                      # history + scheduler tests (node:test) + fetcher tests (go test)
(cd fetcher && go run ./cmd/fetcher --once)              # print current weather, no server, no DB
(cd fetcher && go run ./cmd/fetcher --once --history 2)  # same, hourly data for the last 2 days

curl -X POST localhost:3001/api/weather/fetch
curl -X POST -H 'Content-Type: application/json' -d '{"days":30}' localhost:3001/api/weather/backfill
curl 'localhost:3001/api/weather/latest'
curl 'localhost:3001/api/weather/history?from=2026-09-01&to=2026-09-30'

docker exec -it postgres psql -U postgres -d weather -c 'select count(*) from weather_observations;'
npm run db:down                               # stop PostgreSQL (data stays in the postgres-data volume)
```

## Go for beginners (Fetcher)

The Fetcher is written in Go so that the project has one scripting-language service (History, Node.js) and one
compiled service (Fetcher, Go).

1. **Install Go** (1.22+): `sudo apt install golang-go` (check the version, Ubuntu may ship an older one), or download
   the tarball from https://go.dev/dl/, unpack it to `/usr/local` and add `export PATH=$PATH:/usr/local/go/bin`
   to your `~/.zshrc`. Check with `go version`.
2. **Dependencies**: `fetcher/go.mod` is the equivalent of `package.json` (one dependency, the RabbitMQ client
   `amqp091-go`); `go build` downloads it automatically, `go mod download` does it explicitly.
3. **Run (development)**: `cd fetcher && go run ./cmd/fetcher` compiles and starts it (like `node src/server.js`).
4. **Build a binary**: `cd fetcher && go build -o bin/fetcher ./cmd/fetcher && ./bin/fetcher`. The result is a single
   executable file that runs without Go installed.
5. **Test and check**: `go test ./...`, `go vet ./...`, and `gofmt -l .` (lists unformatted files; `gofmt -w .` fixes them).
6. **Configuration** comes from `fetcher/.env` (copy `fetcher/.env.example`), which the Fetcher reads at start from its
   working directory, so run it from the `fetcher/` folder. Real environment variables override the file, e.g.
   `AMQP_URL=amqp://... go run ./cmd/fetcher`. Without any config it uses RabbitMQ on localhost (guest) and the Open-Meteo forecast URL.
7. **Vocabulary**: a *module* is the whole project (`go.mod`); `cmd/` holds entry points (programs);
   `internal/` holds code that can't be imported from outside the module; a `_test.go` file next to the code is a test.
