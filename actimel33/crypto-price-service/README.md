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

Container logs of all VMs are shipped to `db:/srv/logs/` every 15 minutes.

Details — queue, sessions, images, provisioning, logs: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

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

## SSH by name

`vagrant up` writes `.vagrant/ssh/config`. Add once, as the first line of `~/.ssh/config`:

```
Include /absolute/path/to/crypto-price-service/.vagrant/ssh/config
```

Then `ssh db`, `ssh history`, `scp file ui:` work without `vagrant ssh`.

## Logs

```bash
ssh db sudo ls -R /srv/logs                               # <host>/<container>.log
ssh db sudo tail -f /srv/logs/history/crypto_history.log
for h in db fetcher history ui; do ssh $h sudo logship; done   # ship now, not in 15 min
ssh history sudo journalctl -t logship                    # shipping errors
```

Each VM ships with its own key (`.vagrant/logship/`), limited on db to appending
to its own directory from its own address.

## Operations

```bash
ssh history sudo docker ps
ssh history sudo docker logs -f crypto_history
```

## Layout

```
services/fetcher/   Go worker + Dockerfile
services/history/   Node/TS API + Dockerfile
ui/                 React app, nginx template + Dockerfile
db/migrations/      SQL, applied by history on start
vagrant/            provisioning scripts, lib.sh helpers
logship/            log shipper (cron) and collector-side logsink
Vagrantfile         VM list, secrets, ssh config, logship keys, code delivery
docs/               architecture
```
