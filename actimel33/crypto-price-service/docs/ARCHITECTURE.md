# Architecture

## Machines and traffic

```
                        browser
                           │  http://192.168.77.13:5173
                           ▼
  ┌──────────────┐  /api  ┌──────────────┐
  │      ui      │───────▶│   history    │
  │ 192.168.77.13│        │ 192.168.77.12│
  │ :5173 nginx  │        │  :3001 node  │
  └──────────────┘        └──┬────────┬──┘
                    SQL       │        │  price:requests ▼   ▲ price:results
                              ▼        ▼                 sessions
                   ┌────────────────────────────┐
                   │            db              │
                   │       192.168.77.10        │
                   │  postgres :5432            │
                   │  redis    :6379            │
                   └─────────────▲──────────────┘
                                 │  price:requests ▲  ▼ price:results
                          ┌──────┴───────┐
                          │   fetcher    │──────▶ CoinGecko
                          │ 192.168.77.11│
                          │   :3002 go   │
                          └──────────────┘

  every box runs in docker on its own VM; ports are published on the VM address
```

- only history writes to the database;
- history and fetcher never call each other — both know only the redis address;
- redis shares the db node: the task forbids separate VMs for infrastructure;
- fetcher's HTTP serves `/health` only.

## Queue

```
  price:requests   history → fetcher   { coin, vs, days? }
  price:results    fetcher → history   { coin, vs, origin, points[] }

  consumer groups   fetchers · history       consumer name = hostname
  ack               after success, not on receipt
  reclaim           messages unacked for 30 s are taken over (XAUTOCLAIM)
  dedup             SET pending:<coin>:<vs> NX EX 30 — one quote request in flight
  NOGROUP           group lost on a redis restart is recreated on the fly
  persistence       appendonly yes — queue and sessions survive a restart
  length            MAXLEN ~1000 per stream
```

## Data paths

```
  bootstrap   at start      history → requests{days:7} → fetcher → CoinGecko
                            → results → history → db        ~169 hourly points
  timer       every 12 h    fetcher → CoinGecko → results → history → db
  on demand   a visitor     history answers from db; stale → queues a request
  refresh     button        POST /api/refresh → 202, UI re-reads after ~2.5 s

  no duplicates:  UNIQUE (coin, vs_currency, observed_at) + ON CONFLICT DO NOTHING
                  observed_at comes from CoinGecko, not from our write time
```

## Session

```
  browser ──cookie connect.sid──▶ history ──▶ redis   session:<id>, 30 days

  cookie   s:<id>.<HMAC>   — identifier only, signed with SESSION_SECRET
  value    { preferences: { theme } }   light | dark | system
  issued   on the first visit (saveUninitialized: true)
```

## Build and provisioning

```
  HOST (WSL)                                    GUEST
 ═══════════════════════════════════════════════════════════════════════════
  vagrant up
      ├─ Vagrantfile: MACHINES[] → db, fetcher, history, ui
      ├─ secrets → .vagrant/secrets.env (0600, git-ignored)
      │            POSTGRES_PASSWORD, REDIS_PASSWORD, SESSION_SECRET
      ├─ tar → /tmp/…payload.tgz (~1 MB, no .env / node_modules / bin)
      └─ machines provision IN PARALLEL (vagrant-libvirt)
            │
            ├─ libvirt clone bento/ubuntu-24.04
            │     eth0 192.168.121.x  management, internet
            │     eth1 192.168.77.x   private network
            ├─ code → unpack → /home/vagrant/app
            ├─ system (root)   docker-ce + buildx only, same on every VM
            └─ role (vagrant)  .env from .env.example → docker build → docker run
                  db       volumes pgdata, redisdata → crypto_db, crypto_redis
                  fetcher  wait redis → build crypto/fetcher → crypto_fetcher
                  history  wait db, redis → build crypto/history → crypto_history
                  ui       build crypto/ui → crypto_ui → e2e curl /api/price/latest
```

Images are built on the VM itself — no registry. `vagrant/lib.sh` holds the
helpers: `replace` (rm -f + run), `wait_healthy`, `wait_port`. Waiting is
required: machines start in parallel, the Vagrantfile order is not honoured.
No compose on the VMs — one container per VM, `docker run` is enough.

## Images

```
  image            build stage           runtime                               size
  crypto/fetcher   golang:1.27-alpine    distroless/static-debian12:nonroot   ~19 MB
  crypto/history   node:24-alpine        distroless/nodejs24-debian12:nonroot ~227 MB
  crypto/ui        node:24-alpine        nginx-unprivileged:1.29-alpine        ~82 MB
  postgres         postgres:17-alpine
  redis            redis:7-alpine

  multi-stage      toolchain stays in the build stage
  cache mounts     go mod / npm cache reused between builds (BuildKit)
  go binary        CGO_ENABLED=0 -trimpath -ldflags="-s -w"
  node deps        npm ci --omit=dev
  non-root         distroless :nonroot, nginx-unprivileged on :8080
  .dockerignore    no .git, node_modules, .env, docs, vagrant in the context
```

## Service start-up inside a VM

```
  docker  --restart unless-stopped  HEALTHCHECK in every image
      ├─ crypto_history  --read-only --init   migrations → results consumer
      │                                        → bootstrap → :3001
      ├─ crypto_fetcher  --read-only           requests worker → 12 h timer
      │                                        → :3002 (/health; `fetcher healthcheck`)
      ├─ crypto_ui       -p 5173:8080          nginx: static build, /api → HISTORY_URL
      ├─ crypto_db       -p 5432  volume pgdata      health: pg_isready
      └─ crypto_redis    -p 6379  volume redisdata   requirepass, appendonly yes
```
