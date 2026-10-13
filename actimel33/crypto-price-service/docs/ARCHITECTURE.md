# Architecture

Three services, one Docker container per Vagrant VM, plus a database node.
History and fetcher never call each other: they talk only through a queue,
which lives in Redis or in Postgres depending on `BACKEND`.

## 1. Machines, containers, traffic

```mermaid
flowchart LR
    user(["Browser / phone"])
    cg[("CoinGecko API")]

    subgraph host["WSL host: Vagrant + libvirt/KVM · network 192.168.77.0/24"]
        subgraph vm_ui["VM ui · 192.168.77.13"]
            ui["crypto_ui<br/>nginx-unprivileged<br/>:5173 → :8080<br/>static React build"]
        end
        subgraph vm_history["VM history · 192.168.77.12"]
            history["crypto_history<br/>Node 24 · Express<br/>:3001"]
        end
        subgraph vm_fetcher["VM fetcher · 192.168.77.11"]
            fetcher["crypto_fetcher<br/>Go · :3002 /health only<br/>worker + 12 h timer"]
        end
        subgraph vm_db["VM db · 192.168.77.10"]
            pg[("crypto_db<br/>Postgres 17 + pgmq · :5432<br/>volume pgdata")]
            redis[("crypto_redis · :6379<br/>volume redisdata<br/>BACKEND=redis only")]
            logs[/"/srv/logs<br/>logs of all VMs"/]
        end
    end

    user -->|"HTTP :5173"| ui
    ui -->|"/api/* → /*"| history
    history -->|"SQL: prices, migrations"| pg
    history -.->|"BACKEND=redis<br/>queue + sessions"| redis
    history -->|"BACKEND=postgres<br/>pgmq + session table"| pg
    fetcher -.->|"BACKEND=redis<br/>queue"| redis
    fetcher -->|"BACKEND=postgres<br/>pgmq as queue_worker"| pg
    fetcher -->|"HTTPS"| cg
```

- only history writes prices; fetcher's HTTP serves `/health` only;
- Redis, when used, shares the db node: the task forbids separate VMs for infrastructure;
- from Windows and the router's network the VMs are reached through a route to
  `192.168.77.0/24` and `netsh portproxy` (`<laptop>:5173 → ui`); see the README.

## 2. BACKEND: Redis or Postgres for everything

Chosen at provisioning, read by both services at startup. Both implementations are
built in; switching rebuilds nothing.

| | `BACKEND=redis` (default) | `BACKEND=postgres` |
|---|---|---|
| queue | Redis Streams `price:requests`, `price:results` | pgmq queues `price_requests`, `price_results` |
| sessions | Redis keys `session:<id>` | table `session` |
| containers on db | `crypto_db` + `crypto_redis` | `crypto_db` only |
| fetcher connects to | Redis | Postgres as `queue_worker` |

```text
switch:    BACKEND=postgres vagrant provision db fetcher history
remembered in .vagrant/backend; /health of both services shows the active one
```

Each service has one `Queue` interface with two drivers (`history/src/queue/`,
`fetcher/{redisqueue,pgqueue}.go`); the rest of the code does not know which one runs.
Messages are the same JSON in both: requests `{ coin, vs, days? }`, results
`{ coin, vs, origin, points[] }`.

## 3. Request flows

### Opening the page

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant N as nginx (ui)
    participant H as history
    participant P as Postgres
    participant Q as queue

    B->>N: GET /api/price/latest
    N->>H: GET /price/latest
    H->>P: newest point for bitcoin/usd
    alt fresh (younger than CACHE_TTL, 15 min)
        H-->>B: 200 { price, stale: false }
    else stale
        H->>Q: request { coin, vs } (deduplicated)
        H-->>B: 200 { price, stale: true }
        loop every 4 s while stale
            B->>N: GET /api/price/latest
        end
    else nothing stored yet
        H->>Q: request { coin, vs }
        H-->>B: 503 "a request has been queued"
    end
    B->>N: GET /api/price/history (7 days, for the chart)
```

### Refresh button

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant H as history
    participant Q as queue
    participant F as fetcher
    participant C as CoinGecko
    participant P as Postgres

    B->>H: POST /api/refresh (through nginx)
    H->>Q: request { bitcoin, usd }
    H-->>B: 202 { queued: true }  (false if one already waits)
    F->>Q: read (lease 30 s)
    F->>C: /simple/price
    C-->>F: price + last_updated_at
    F->>Q: result { origin: on_demand, points }
    F->>Q: ack the request
    H->>Q: read result
    H->>P: INSERT … ON CONFLICT DO NOTHING
    H->>Q: ack the result
    Note over B: re-reads /price/latest after 2.5 s
```

Other paths through the same queue:

| path | trigger | request | result origin |
|---|---|---|---|
| bootstrap | history start, empty table | `{ coin, vs, days: 7 }` → `/market_chart` | `bootstrap`, ~169 hourly points |
| timer | fetcher, every 12 h | none, fetcher publishes on its own | `timer` |
| on demand | stale or missing price, Refresh | `{ coin, vs }` → `/simple/price` | `on_demand` |

- no duplicate points: `UNIQUE (coin, vs_currency, observed_at)` + `ON CONFLICT DO NOTHING`;
  `observed_at` comes from CoinGecko, not from our write time;
- only the default pair or one already stored can be fetched; any other `coin`/`vs` → 404,
  so a stray name never costs a CoinGecko call.

## 4. Queue delivery

```mermaid
sequenceDiagram
    autonumber
    participant S as sender
    participant Q as queue
    participant R as receiver

    S->>Q: send message
    R->>Q: read: message leased to R
    Note over Q: invisible to others while leased (30 s)
    alt work done
        R->>Q: ack → message removed
    else R crashed or the work failed
        Note over Q: no ack for 30 s
        R->>Q: next read gets it again (any instance)
    else malformed message or upstream 4xx
        R->>Q: ack anyway: a retry cannot help
    end
```

| | Redis Streams | pgmq (Postgres) |
|---|---|---|
| read | `XREADGROUP BLOCK 5 s` | `pgmq.read_with_poll`, waits 5 s on the server |
| lease | pending entry list | visibility timeout `vt` = 30 s |
| ack | `XACK` | `pgmq.delete` |
| retry | `XAUTOCLAIM` after 30 s idle | `vt` expires, the message is visible again |
| dedup of quote requests | `SET pending:<coin>:<vs> NX EX 30` | unique index on waiting quotes, `23505` = already queued |
| survives a restart | `appendonly yes` | tables in `pgdata` |
| several readers | consumer groups `fetchers`, `history`; consumer = hostname | no groups: any reader takes the next visible message |

- history reads results on a Redis connection of its own: commands on one connection
  run in order, and a blocking read would stall every session lookup behind it;
- `queue_worker` (fetcher's Postgres login, `003_pgmq.sql`): `SELECT, UPDATE, DELETE` on
  requests, `SELECT, INSERT` on results — no prices, no sessions, cannot drop a queue.

## 5. Session (theme)

```mermaid
sequenceDiagram
    participant B as Browser
    participant H as history
    participant S as session store

    B->>H: GET /session (first visit, no cookie)
    H->>S: create session
    H-->>B: { theme: system } + Set-Cookie connect.sid
    B->>H: PUT /session/theme { dark } + cookie
    H->>S: save { preferences: { theme: dark } }
    H-->>B: { theme: dark }
    Note over B,H: next visit or reload: GET /session → dark
```

| | |
|---|---|
| store | Redis `session:<id>` or table `session`, by `BACKEND`; 30 days |
| cookie | `s:<id>.<HMAC>` — identifier only, signed with `SESSION_SECRET`, `HttpOnly`, `SameSite=Lax` |
| scope | session middleware runs after the health and price routes: they create no session |

## 6. Provisioning

```mermaid
flowchart TD
    host["<b>Host</b> · the Vagrantfile, read on every vagrant command<br/>secrets · BACKEND · ROLE_ENV · logship keys · ssh config · payload"]
    par{{"4 VMs provision in parallel"}}
    host ==> par
    par --> db_s & f_s & h_s & u_s

    subgraph db_vm["db"]
        db_s["code · unpack · system"] --> db_r["role<br/>build crypto/postgres:17-pgmq<br/>run crypto_db<br/>queue_worker password<br/>crypto_redis if redis"] --> db_c["collector<br/>user logs, logsink,<br/>logrotate"] --> db_l["logship"]
    end
    subgraph f_vm["fetcher"]
        f_s["code · unpack · system"] --> f_w["wait for db<br/>:6379 or :5432"] --> f_r["role<br/>build + run<br/>crypto_fetcher"] --> f_l["logship"]
    end
    subgraph h_vm["history"]
        h_s["code · unpack · system"] --> h_w["wait for db<br/>:5432 (+ :6379)"] --> h_r["role<br/>build + run<br/>crypto_history"] --> h_l["logship"]
    end
    subgraph u_vm["ui"]
        u_s["code · unpack · system"] --> u_r["role<br/>build + run<br/>crypto_ui"] --> u_w["wait for history<br/>:3001"] --> u_e["e2e<br/>/api/health"] --> u_l["logship"]
    end
```

Host side, written by the Vagrantfile into `.vagrant/` (git-ignored):

| file | what |
|---|---|
| `secrets.env` | `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `SESSION_SECRET`, `QUEUE_WORKER_PASSWORD`; 0600, generated once |
| `backend` | the last `BACKEND`, so a later `vagrant provision` keeps it |
| `logship/` | one ssh key per VM + `authorized_keys` for the collector |
| `ssh/config` | `ssh db` and friends from the host |
| `payload.tgz` | the project, ~1 MB, shipped to every VM (no synced folder) |

| step | runs as | does |
|---|---|---|
| code, unpack | root | archive → `/home/vagrant/app`, replaced, not merged |
| system | root | Docker CE + buildx; `json-file` logs capped 3 × 10 MB |
| role | vagrant | writes a 0600 env file with exactly the container's variables → `docker build` → `docker run --env-file` |
| collector | root, db only | user `logs`, `/usr/local/bin/logsink`, `authorized_keys`, logrotate |
| logship | root | key, `/usr/local/bin/logship`, cron every 15 min |

`vagrant/lib.sh`: `env_file` (secrets never on a command line), `replace` (graceful stop,
then run), `wait_healthy`, `wait_port` (up to 5 min). Waiting is required: the
Vagrantfile order is not honoured. Images are built on each VM, no registry, no compose.

**Who gets which variables**

| container | variables |
|---|---|
| `crypto_db` | `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD` |
| `crypto_redis` | `REDIS_PASSWORD` |
| `crypto_history` | `BACKEND`, `HISTORY_HOST`, `DATABASE_URL`, `SESSION_SECRET` (+ `REDIS_URL`, `REDIS_PASSWORD`) |
| `crypto_fetcher` | `BACKEND`, `FETCHER_HOST`, then `REDIS_URL` + `REDIS_PASSWORD` **or** `QUEUE_DATABASE_URL` |
| `crypto_ui` | `HISTORY_URL` — no secrets |

## 7. Containers and images

| container | image (build → runtime) | runs with | health |
|---|---|---|---|
| `crypto_ui` | node:24-alpine → nginx-unprivileged:1.29-alpine, ~82 MB | `-p 5173:8080` | `wget /` |
| `crypto_history` | node:24-alpine → distroless/nodejs24:nonroot, ~227 MB | `--read-only --init` | `fetch /health` |
| `crypto_fetcher` | golang:1.27-alpine → distroless/static:nonroot, ~19 MB | `--read-only` | `fetcher healthcheck` |
| `crypto_db` | postgres:17-alpine + pgmq SQL files | volume `pgdata` | `pg_isready -h 127.0.0.1` |
| `crypto_redis` | redis:7-alpine | volume `redisdata`, `appendonly yes` | `redis-cli ping` |

All: `--restart unless-stopped` (back after a reboot), non-root where the image allows,
multi-stage builds with BuildKit cache mounts, `npm ci --omit=dev`,
Go `CGO_ENABLED=0 -trimpath -ldflags="-s -w"`, `.dockerignore` keeps the context small.

History at start: migrations (advisory lock) → results consumer → bootstrap → listen :3001.

## 8. SSH from the host

```text
~/.ssh/config:  Include <project>/.vagrant/ssh/config      (first line)

Host db        HostName 192.168.77.10   IdentityFile .vagrant/machines/db/libvirt/private_key
Host fetcher   HostName 192.168.77.11   …
User vagrant · IdentitiesOnly · no host key check (VMs are recreated)
```

Generated from `MACHINES` on every Vagrant run; keys are the per-machine ones Vagrant
creates on the first `up`.

## 9. Logs

```mermaid
flowchart LR
    subgraph vm["every VM · cron */15 · root"]
        c["containers<br/>stdout / stderr"] --> j["Docker json-file<br/>3 × 10 MB per container"]
        j -->|"docker logs --since prev --until now"| sp["/var/spool/logship/<br/>container.ts.log"]
    end
    subgraph db["db"]
        ls["logsink host"] --> f["/srv/logs/host/container.log<br/>0640 · logrotate daily × 7"]
    end
    sp -->|"ssh logs@db container, batch on stdin<br/>deleted only after success"| ls
```

`authorized_keys` of user `logs` on db, one line per VM:

```text
restrict,from="192.168.77.12",command="/usr/local/bin/logsink history" ssh-ed25519 … logship@history

restrict   no shell, PTY, port / agent / X11 forwarding
from=      the key works only from that VM's address
command=   any request runs logsink; the host is fixed by the key,
           the client only names the container: ^[a-z0-9_-]{1,64}$
```

- collector unreachable → batches wait in the spool, the next run sends them;
  if `docker` fails, the window is read again: duplicates beat gaps;
- `flock`: runs never overlap; `docker ps -a`: stopped containers are read too;
- one batch is capped at 50 MB; `authorized_keys` is owned by root;
- retention: db keeps today + 7 rotated days; each VM keeps up to 30 MB per container.

## 10. Known limits

- delivery of logs lags up to 15 min; a dropped connection mid-batch may duplicate part of it;
- switching `BACKEND` does not carry queued messages or sessions over (one request at most,
  the theme resets);
- `StrictHostKeyChecking no` for ssh between VMs and from the host: VMs are recreated;
- no disk quota for `/srv/logs` beyond the per-batch cap;
- one instance of each service: the container hostname is the Redis consumer name.
