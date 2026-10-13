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
                    SQL       │        │  requests ▼   ▲ results
                              ▼        ▼          sessions
                   ┌────────────────────────────┐
                   │            db              │
                   │       192.168.77.10        │
                   │  postgres :5432  (+ pgmq)  │
                   │  redis    :6379  (redis)   │
                   └─────────────▲──────────────┘
                                 │  requests ▲  ▼ results
                          ┌──────┴───────┐
                          │   fetcher    │──────▶ CoinGecko
                          │ 192.168.77.11│
                          │   :3002 go   │
                          └──────────────┘

  every box runs in docker on its own VM; ports are published on the VM address
```

- only history writes prices; history and fetcher never call each other;
- fetcher's HTTP serves `/health` only;
- `BACKEND` (below) decides whether Redis exists at all; when it does, it shares
  the db node: the task forbids separate VMs for infrastructure.

## BACKEND: Redis or Postgres for everything

Chosen at provisioning, read by the services at startup; both implementations
are built in, nothing is rebuilt to switch.

```
                 BACKEND=redis (default)          BACKEND=postgres
  queue          Redis Streams                    pgmq extension
  sessions       Redis                            table "session"
  containers     crypto_db + crypto_redis         crypto_db only
  fetcher logs   Redis                            postgres as queue_worker
  in as

  switch:   BACKEND=postgres vagrant provision db fetcher history
            remembered in .vagrant/backend; /health of both services shows it
```

Messages are the same JSON in both: requests `{ coin, vs, days? }` history →
fetcher, results `{ coin, vs, origin, points[] }` fetcher → history. Each service
has one `Queue` interface with two drivers; the rest of the code does not know
which one runs.

## Queue

```
                  Redis Streams                     pgmq (Postgres)
  queues          price:requests, price:results     price_requests, price_results
  read            XREADGROUP BLOCK 5 s              read_with_poll, waits 5 s
  in-flight       pending entry list                visibility timeout (vt) 30 s
  ack             XACK after success                pgmq.delete after success
  retry           XAUTOCLAIM after 30 s             vt expires → visible again
  dedup           SET pending:<pair> NX EX 30       unique index on waiting quotes
  persistence     appendonly yes                    tables in pgdata

  both: ack only after the work is done; a malformed message is dropped,
        not retried; an upstream 4xx is dropped, not asked again every 30 s
```

- history reads results on a Redis connection of its own: a blocking read would
  stall every session lookup behind it.
- `queue_worker`, the fetcher's Postgres login, can read requests and write
  results — not prices, not sessions, not drop queues (`003_pgmq.sql`).
- the db image is `postgres:17-alpine` plus pgmq's SQL files (`db/Dockerfile`):
  pgmq is pure SQL, nothing is compiled, the base image stays the same.

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
  browser ──cookie connect.sid──▶ history ──▶ redis     session:<id>, 30 days
                                             └▶ postgres  table "session" (BACKEND=postgres)

  cookie   s:<id>.<HMAC>   — identifier only, signed with SESSION_SECRET
  value    { preferences: { theme } }   light | dark | system
  issued   on the first /session call (saveUninitialized: true);
           price routes are mounted before the session middleware and create none
```

## Build and provisioning

```
  HOST (WSL)                                    GUEST
 ═══════════════════════════════════════════════════════════════════════════
  vagrant up
      ├─ Vagrantfile: MACHINES[] → db, fetcher, history, ui
      ├─ secrets → .vagrant/secrets.env (0600, git-ignored)
      │            POSTGRES_PASSWORD, REDIS_PASSWORD, SESSION_SECRET, QUEUE_WORKER_PASSWORD
      ├─ ROLE_ENV  each machine gets only the variables its containers need
      ├─ .vagrant/ssh/config         `ssh <name>` from the host
      ├─ .vagrant/logship/<name>      one ssh key per VM + authorized_keys
      ├─ tar → .vagrant/payload.tgz (~1 MB, no .env / node_modules / bin)
      └─ machines provision IN PARALLEL (vagrant-libvirt)
            │
            ├─ libvirt clone bento/ubuntu-24.04
            │     eth0 192.168.121.x  management, internet
            │     eth1 192.168.77.x   private network
            ├─ code → unpack → /home/vagrant/app (replaced, not merged)
            ├─ system (root)   docker-ce + buildx, json-file logs capped 3 × 10 MB
            ├─ role (vagrant)  0600 env file → docker build → docker run --env-file
            │     db       build crypto/postgres:17-pgmq → crypto_db, queue_worker
            │              password; crypto_redis only with BACKEND=redis
            │     fetcher  wait db (redis or 5432) → build → crypto_fetcher
            │     history  wait db, redis → build → crypto_history
            │     ui       build → crypto_ui → wait history → e2e curl /api/health
            ├─ collector (db, root)  user logs, logsink, authorized_keys, logrotate
            └─ logship (root)        key, /usr/local/bin/logship, cron */15
```

Images are built on the VM itself — no registry. `vagrant/lib.sh` holds the
helpers: `env_file` (named variables → 0600 file, so secrets never reach a
command line), `replace` (graceful stop, then run), `wait_healthy`, `wait_port`
(up to 5 min). Waiting is required: machines start in parallel, the Vagrantfile
order is not honoured. No compose on the VMs — one container per VM.

## Images

```
  image            build stage           runtime                               size
  crypto/fetcher   golang:1.27-alpine    distroless/static-debian12:nonroot   ~19 MB
  crypto/history   node:24-alpine        distroless/nodejs24-debian12:nonroot ~227 MB
  crypto/ui        node:24-alpine        nginx-unprivileged:1.29-alpine        ~82 MB
  crypto/postgres  postgres:17-alpine    + pgmq SQL files (db/Dockerfile)
  redis            redis:7-alpine        BACKEND=redis only

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
      ├─ crypto_db       -p 5432  volume pgdata      health: pg_isready -h 127.0.0.1
      └─ crypto_redis    -p 6379  volume redisdata   requirepass, appendonly yes
                                                     (BACKEND=redis only)
```

## SSH from the host

```
  ~/.ssh/config:  Include <project>/.vagrant/ssh/config      (first line)

  Host db        HostName 192.168.77.10   IdentityFile .vagrant/machines/db/libvirt/private_key
  Host fetcher   HostName 192.168.77.11   …
  User vagrant · IdentitiesOnly · no host key check (VMs are recreated)
```

Generated from `MACHINES` on every Vagrant run; keys are the per-machine ones
Vagrant creates on the first `up`.

## Logs

```
  every VM, cron */15 (root)                              db
  docker logs --since <prev> --until <now>   ssh logs@db
    → /var/spool/logship/<container>.<ts>.log ──────────▶ logsink <host>
    → deleted after the collector took it                 → /srv/logs/<host>/<container>.log
                                                            logrotate daily × 7, gzip
```

```
  authorized_keys of user logs, one line per VM:
  restrict,from="192.168.77.12",command="/usr/local/bin/logsink history" ssh-ed25519 … logship@history

  restrict   no shell, PTY, port / agent / X11 forwarding
  from=      key works only from that VM's address
  command=   any request runs logsink; host is fixed by the key,
             the client only names the container: ^[a-z0-9_-]{1,64}$
```

- collector unreachable → batches stay in the spool, the next run sends them in order;
- `flock` — runs never overlap; `docker ps -a` — stopped containers are read too;
- logs on db: `0640 logs:logs`; `authorized_keys` is owned by root;
- retention: db keeps today + 7 rotated days (logrotate); on each VM Docker keeps
  up to 3 × 10 MB per container (`/etc/docker/daemon.json`);
- known limits: delivery delay up to 15 min; a dropped connection mid-batch may
  duplicate part of it; the last ≤15 min of a container removed between runs are lost;
  `StrictHostKeyChecking no` on senders; no disk quota for `/srv/logs`.
