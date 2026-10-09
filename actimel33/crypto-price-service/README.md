# Crypto Price Service

Bitcoin price and 7-day history from CoinGecko. Three services, each in a
Docker container on its own Vagrant VM.

```
browser → ui (nginx) → history (Node/TS) → PostgreSQL
                            ↕ Redis Streams
                        fetcher (Go) → CoinGecko
```

| VM      | Address        | Port | Container                   |
|---------|----------------|------|-----------------------------|
| db      | 192.168.77.10  | 5432 | `crypto_db` (postgres:17)   |
|         |                | 6379 | `crypto_redis` (redis:7)    |
| fetcher | 192.168.77.11  | 3002 | `crypto_fetcher`            |
| history | 192.168.77.12  | 3001 | `crypto_history`            |
| ui      | 192.168.77.13  | 5173 | `crypto_ui`                 |

Details — queue, sessions, images, provisioning: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Run on VMs

Requires Vagrant with the libvirt provider (KVM). The Vagrantfile selects
libvirt by default.

```bash
vagrant up                  # all four VMs, provisioned in parallel
vagrant up history          # a single VM
vagrant provision ui        # rebuild and restart one service
vagrant destroy -f          # tear down
```

Open <http://192.168.77.13:5173>. The `ui` provisioner ends with an end-to-end
check through `/api/price/latest`.

Secrets (`POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `SESSION_SECRET`) are generated
on the first `vagrant up` into `.vagrant/secrets.env` and never committed.
Each VM builds its `.env` from `.env.example`.

## Run locally

Requires Docker, Go 1.27, Node 24.

```bash
cp .env.example .env        # set the passwords
./dev.sh                    # PostgreSQL + Redis in compose, services as processes
```

UI on <http://localhost:5173>, logs in `logs/`.

## API (history)

| Method | Path                 | Purpose                               |
|--------|----------------------|---------------------------------------|
| GET    | `/api/price/latest`  | latest quote, marked stale if old     |
| GET    | `/api/price/history` | hourly points for the chart           |
| POST   | `/api/refresh`       | queue a fetch, returns 202            |
| GET    | `/api/session`       | stored theme                          |
| PUT    | `/api/session/theme` | save theme: `light`, `dark`, `system` |
| GET    | `/health`            | liveness (history and fetcher)        |

## Operations

```bash
vagrant ssh history -c 'sudo docker ps'
vagrant ssh history -c 'sudo docker logs -f crypto_history'
```

## Layout

```
services/fetcher/   Go worker + Dockerfile
services/history/   Node/TS API + Dockerfile
ui/                 React app, nginx template + Dockerfile
db/migrations/      SQL, applied by history on start
vagrant/            provisioning scripts, lib.sh helpers
Vagrantfile         VM list, secrets, code delivery
docs/               architecture
```
