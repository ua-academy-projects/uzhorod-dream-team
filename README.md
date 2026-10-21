# POI Finder

POI services in Rust: **fetcher** (Overpass → queue + cache) and **history** (queue → Postgres).
Infrastructure is Vagrant (`Vagrantfile`, `provision/`), deployment is `deploy/`.

## Modes: primary / fallback

The mode is set by **`PG_BACKEND`** in `deploy/queue.env` (together with the URLs of all backends). The cache is paired with the queue:

| `PG_BACKEND` | queue | cache (fetcher only) |
|---|---|---|
| `0` (default) — **primary** | RabbitMQ (`RABBITMQ_URL`) | Redis (`REDIS_URL`) |
| `1` — **fallback** | pgmq (`PGMQ_URL`) | `cache` table (hstore) in the same DB as `PGMQ_URL` |

An empty value or anything other than `0`/`1` is treated as `0` (`set-queue.sh` warns about values that are not 0/1).
The services do not know about this switch: from `queue.env` `set-queue.sh` builds only `QUEUE_URL` (= `RABBITMQ_URL` or `PGMQ_URL`)
and `REDIS_URL` for the VMs, and the fetcher and history pick the backend by the scheme of `QUEUE_URL`.

Switching is configuration only, there is no automatic fallback: the fetcher and history always use the same backend.

```sh
deploy/set-queue.sh 1        # PG_BACKEND=1 (the 0|1 argument rewrites it in deploy/queue.env; without an argument the file is used as is)
                             # stops the fetcher → stops history → rolls out the config → starts history, then the fetcher
```

Messages left in the old queue will not be seen by history, so before switching let it drain the old queue
(`/stats`: the counters stop growing, the queue holds 0 messages).

## Variables

| Variable | Service | Default | Purpose |
|---|---|---|---|
| `QUEUE_URL` | fetcher, history | — (fetcher: queue and cache disabled; history: required) | queue and cache backend by scheme (`amqp(s)://` / `postgres(ql)://`); `set-queue.sh` writes it on the VMs |
| `REDIS_URL` | fetcher | — | Redis for the cache when `QUEUE_URL=amqp://…` (without it the cache is disabled) |
| `CACHE_TTL_SECS` | fetcher | `3600` | cache TTL |
| `OVERPASS_URLS` | fetcher | overpass-api.de | comma-separated list of endpoints |
| `DATABASE_URL` | history | — (required) | history DB (`fetch_results`, `poi`); migrations are applied on startup |
| `PORT` | fetcher / history | `8080` / `8081` | HTTP: fetcher — API, history — `/healthz`, `/stats` |
| `RUST_LOG` | history | `info,sqlx=error` | log level (tracing; sqlx errors only, because the pgmq long poll is normally "slow") |

## history

Reads `poi.fetched` and `fetch.failed` (RabbitMQ: queues `poi.fetched`/`fetch.failed`; pgmq: `poi_fetched`/`fetch_failed`)
and writes to Postgres: `fetch_results` (a row per message) and `poi` (the elements of successful requests).

- At-least-once delivery, idempotent on `msg_id`; a message is acknowledged only after the commit.
- A corrupted message or an unknown `schema` → `reject` (pgmq: archive `pgmq.a_<queue>`; RabbitMQ: dropped).
- A DB error → `nack` (redelivery); in pgmq after 5 attempts → `reject`.
- `GET :8081/healthz` — 200 if the DB responds, otherwise 503. `GET :8081/stats` — per-topic counters
  (`saved`, `duplicates`, `nacked`, `rejected`, `queue_errors`). The port is open to the bastion only.

## frontend

A static site without a build step: `frontend/` (plain JS + Leaflet from unpkg with SRI, OSM tiles). The browser talks only to the nginx on the bastion
(`http://192.168.50.10/`, the same origin, no CORS needed):

| Path | Goes to |
|---|---|
| `/` | the `frontend` VM (10.10.0.20), static files |
| `/api/pois`, `/api/healthz` | fetcher `GET /pois`, `GET /healthz` (10.10.0.21:8080) |
| the rest of `/api/*` | 404; non-GET methods — 403 |

`/api/pois` has a `limit_req` (30 requests/min, burst 10), because every cache miss hits Overpass; going over it gives 429.
The bastion nginx is defined in `provision/bastion.sh`, the site in `provision/frontend.sh`. To update the files run `deploy/frontend.sh`
(it is part of `deploy/up.sh`). The bastion has an input filter: SSH and HTTP only from the dmz subnet.

## Public access (Cloudflare Tunnel)

Optional: the bastion can publish the site on the internet through a Cloudflare Tunnel (`provision/cloudflared.sh`), without opening inbound ports
and without being tied to the same Wi-Fi. It needs a domain in Cloudflare (the DNS zone must be there) and a free Zero Trust account.

1. Zero Trust -> Networks -> Tunnels -> create a tunnel (Cloudflared); in "Public hostname" set your subdomain
   and the service `http://localhost:80`.
2. Put the tunnel token into `deploy/cloudflared.env` (template: `deploy/cloudflared.env.example`, the file is in `.gitignore`).
3. `vagrant provision bastion --provision-with cloudflared-env,cloudflared` (during `vagrant up` the same happens by itself).

The tunnel is an outbound connection (HTTP/2, TCP 7844). Without a token only the binary and the unit are installed, the service does not start.
nginx trusts the `CF-Connecting-IP` header only from `127.0.0.1`, so `limit_req` counts the real visitor.
The site becomes available to the whole internet; the audience can be restricted with Cloudflare Access (login by email).
A quick tunnel (`trycloudflare.com`) does not work here: its API is unreachable from this network.

## Local Overpass

Public Overpass servers are unstable, so you can keep your own on the host (podman, image `wiktorn/overpass-api`, the Ukraine extract from Geofabrik).
The fetcher goes through `OVERPASS_URLS` in order, so the local one goes first and the public ones stay as a fallback:
`OVERPASS_URLS=http://192.168.50.1:12345/api/interpreter,https://overpass-api.de/api/interpreter,...` (in `deploy/env/fetcher.env`;
apply with `vagrant provision fetcher --provision-with svc-env,svc-install`, then `sudo systemctl restart fetcher` on the VM).

- **Import (once, ~30-60 min, ~8-12 GB):** `podman run` with `OVERPASS_MODE=init`, `OVERPASS_PLANET_URL=.../ukraine-latest.osm.pbf`,
  `OVERPASS_PLANET_PREPROCESS='mv /db/planet.osm.bz2 /db/planet.osm.pbf && osmium cat -o /db/planet.osm.bz2 /db/planet.osm.pbf && rm /db/planet.osm.pbf'`
  and the volume `~/overpass_db:/db:Z`. In `init` mode the container **exits** after the import (marker `/db/init_done`).
- **Running:** the same volume, but no import any more, and the port bound only to the address of the lab network so it is not exposed to the home Wi-Fi:
  `podman run -d --name overpass_ukraine --restart=unless-stopped -e OVERPASS_META=yes -v ~/overpass_db:/db:Z -p 192.168.50.1:12345:80 wiktorn/overpass-api`.
- **Host firewall.** The firewalld zone `libvirt` rejects (`reject`) everything except dhcp/dns/ssh/tftp, so the VMs cannot reach the port until it is allowed.
  The narrowest rule: only the bastion (the NAT address all VMs go out through) and only this port:
  `sudo firewall-cmd --permanent --zone=libvirt --add-rich-rule='rule family=ipv4 source address=192.168.50.10 port port=12345 protocol=tcp accept' && sudo firewall-cmd --reload`.
- **Limitations:** data covers Ukraine only (outside it the response is successful but empty, and the fallback servers are not tried), data updates are not configured,
  and it depends on the host being up and the container running.

## Logs

A cron job on `db` pulls new journald lines of the fetcher, history and the bastion nginx every 15 minutes (`/etc/cron.d/logpull`)
and appends them to `/var/log/reload/<vm>/<source>.log` (fetcher/fetcher.log, history/history.log, bastion/nginx-access.log,
bastion/nginx-error.log; the collector's own log is `/var/log/reload/logpull.log`). Rotated daily, kept for 14 days.

- **Incremental.** The journald cursor is kept on db (`/var/lib/logpull`), so there are no duplicates or gaps between runs.
- **Minimal privileges.** The `logpull` key on the targets has `restrict`, `from="10.10.0.25"` and the forced command `logpull-serve`:
  only four `journalctl` queries are allowed (unit fetcher/history, tags nginx_access/nginx_error). The firewall lets SSH in from db only on the fetcher, history and bastion.
- **Source list** — `/etc/logpull.conf` on db (a line is `<ip> <unit:X|tag:X> <file>`); a new source also needs a matching
  selector in `provision/logpull-target.sh`.
- The bastion nginx writes access/error to journald as well (tags `nginx_access`, `nginx_error`), from where the collector picks them up.
- Manual run: `sudo -u logpull /usr/local/bin/logpull`. Read: `sudo tail -f /var/log/reload/fetcher/fetcher.log`.
- The journal on the sources lives in memory: on a VM reboot lines not yet pulled (up to 15 minutes) are lost.

## Tests

```sh
cargo test                                    # in fetcher/ and history/ — no external services
TEST_PG_URL=postgres://… TEST_AMQP_URL=amqp://… TEST_REDIS_URL=redis://… \
  cargo test -- --ignored --test-threads=1    # live brokers (a DB with the pgmq extension)
```

## Deploy

`deploy/up.sh` = `vagrant up` + `deploy/build.sh` (musl build of both services, upload to the `fetcher`/`history` VMs) + `deploy/frontend.sh` + `deploy/set-queue.sh`.
Secrets (`deploy/queue.env`, `deploy/env/*.env`) are in `.gitignore`; templates are `*.example`.
