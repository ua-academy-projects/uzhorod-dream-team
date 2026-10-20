# Infrastructure (Vagrant + Docker)

How the [Vagrantfile](../Vagrantfile) and the scripts in [provision/](../provision/) build the VMs and run the
services on them as Docker containers (four VMs for the services, plus a bastion for SSH). The code itself has no comments; this file explains it.

Provisioning installs Docker, writes the env and config files that hold the secrets, builds the images on the VM
and starts the containers with plain `docker run`. There are no systemd units of our own and no docker compose:
every container has `--restart unless-stopped`, so the Docker daemon (enabled at boot) starts them again after a
reboot and restarts any container that exits.

## Commands

```bash
vagrant up                                   # all VMs: Docker, /etc/weather/*, images, containers
vagrant up weather-history                   # a single VM
vagrant provision <vm>                       # rewrite env/config files, rebuild images, recreate containers
vagrant reload weather-frontend --provision  # needed after network/RAM changes (e.g. a new adapter)
vagrant ssh <vm> -c "docker ps"
```

## Topology

| VM | Internal IP | Containers | Published ports |
|---|---|---|---|
| `weather-postgres-db` | 192.168.56.10 | `true`: `postgres` (plain `postgres:16-alpine`), `redis`, `rabbitmq`; `false`: `postgres` (`weather/postgres`, with pgmq and pg_cron) | 5432 (and 6379, 5672, 15672 with `true`) on 192.168.56.10 only |
| `weather-fetcher` | 192.168.56.11 | `fetcher` (no port, RabbitMQ worker) | — |
| `weather-history` | 192.168.56.12 | `history`, `scheduler` (Docker network `weather`) | 3001 on 192.168.56.12 only |
| `weather-frontend` | 192.168.56.13 + LAN (DHCP) | `frontend` (nginx, static UI + `/api` proxy) | 4173 → 8080 on all interfaces |
| `weather-bastion` | 192.168.56.14 + LAN (DHCP) | none (no Docker), SSH jump host only, see [Bastion](#bastion) | — |

The VMs share the VirtualBox **internal network** `weather` (`private_network` with `virtualbox__intnet`,
192.168.56.0/24). Unlike a host-only network, the host has no interface in it, so from the host the VMs and their
ports are reachable only through the bastion (see [Bastion](#bastion)) or `vagrant ssh`; the frontend and the
bastion are also in the LAN. The VMs talk to each other exactly as before: a client uses the other VM's IP and the published port. Docker
publishes a port with DNAT, which keeps the client's source IP, so `pg_hba.conf` can still allow the History
VM only. On the History VM the scheduler reaches History by name (`http://history:3001`) over the user-defined
network `weather`, which has its own DNS.

## Vagrantfile

- **Secrets** live in the (gitignored) root `.env`, never in the Vagrantfile. It is parsed as `KEY=VALUE` lines
  (no quotes: everything after the first `=` is the value). `POSTGRES_PASSWORD`, `FETCHER_DB_PASSWORD`,
  `REDIS_PASSWORD` and `RABBITMQ_PASSWORD` are required (provisioning prepares both backends, so a switch needs no secrets later); `vagrant up` aborts with
  "Set … in .env" if one is empty.
- **`USE_REDIS_RABBITMQ`** (default `true`): where the cache and the History ↔ Fetcher queues live, see
  [architecture.md#backends](architecture.md#backends). Empty or missing means `true`; `true/false`, `1/0`, `yes/no`
  in any case are accepted, anything else aborts (a typo should not silently keep the old backend). It is the
  mode the DB, Fetcher and History VMs start in; [`weather-backend`](#switching-the-backend-at-run-time) switches them
  later without provisioning and without building.
- **`VMS`**: one entry per VM; add an entry here to add a machine.
  - `ip`, `memory`, `cpus` (default 1); the DB VM has 1536 MB because with `true` it runs three containers;
  - `script`: provisioning for that VM (from `provision/`);
  - `sync`: the service directories mounted on the VM (see *Synced folders*);
  - `env`: the `PROVISION_ENV` keys its script uses;
  - `lan: true`: also bridge the VM into the host's LAN (DHCP from the router) so other devices can reach it;
  - `bastion: true`: the SSH jump host (exactly one VM); its IP becomes `BASTION_IP`, see [Bastion](#bastion).
- **`PROVISION_ENV`** holds everything the provisioning scripts may need: where each service lives (`DB_IP`,
  `FETCHER_IP`, `HISTORY_IP`) plus secrets and settings from the host `.env` (`POSTGRES_DB`, `TRIGGER_TOKEN`, `CRON_SCHEDULE`, …).
  Each VM gets only its `env` keys plus `SSH_PUBKEY` (`PROVISION_ENV.slice`), so e.g. the frontend VM receives no
  password at all and the fetcher VM only `RABBITMQ_PASSWORD` and `FETCHER_DB_PASSWORD`. A script that starts using a new variable needs it
  added to its VM's `env` (the `: "${VAR:?}"` checks at the top of the scripts fail otherwise).
  `setting.(key, default)` takes a value from `.env` and falls back to the default if it is missing or empty.
- **Ports** are settings too, so each is defined in one place and every script that needs it (the published port
  of the service and the URLs of its clients) gets the same value:

  | `.env` key | Default | Used by |
  |---|---|---|
  | `HISTORY_PORT` | 3001 | History (`PORT`); the scheduler's URL; the nginx proxy target |
  | `FRONTEND_PORT` | 4173 | `-p` of the frontend; the `show-lan-ip` URL |
  | `POSTGRES_PORT` | 5432 | `-p` of postgres; `DATABASE_URL` (also used by docker-compose locally) |
  | `REDIS_PORT` | 6379 | `-p` of redis; `REDIS_URL` |
  | `RABBITMQ_PORT` | 5672 | `-p` of rabbitmq; `AMQP_URL` of History and Fetcher |
  | `RABBITMQ_UI_PORT` | 15672 | `-p` of the RabbitMQ management UI |

  After changing a port, re-provision the VM that runs the service and the VMs of its clients, e.g. for
  `REDIS_PORT`: `vagrant provision weather-postgres-db weather-history`.
- **Synced folders**: the default sync of the whole project root is disabled. Each VM gets only the directories of
  its own services (`sync:` in `VMS`; the db VM only `postgres/`, for its image), mounted read-only
  (`type: "virtualbox"`, `ro`) at `/vagrant/<dir>`. The mounts are live, so `vagrant provision` always builds the
  current code. The VMs never see the root `.env`, `.git` or `.vagrant/` (which holds the private SSH keys of all
  VMs) and cannot write to the host. The local `.env`, `node_modules/`, `dist/` and `bin/` inside a service
  directory are visible on the VM but never reach an image: each `Dockerfile.dockerignore` is an allowlist.
- **SSH key**: `id_ed25519.pub` (gitignored) is read on the host and passed as `SSH_PUBKEY`; `base_setup` writes it
  to `~vagrant/.ssh/authorized_keys`. Every VM except the bastion also gets `BASTION_IP`, and there the key line is
  prefixed with `from="<BASTION_IP>"`, so the key works only through the bastion (see [Bastion](#bastion)). `vagrant up` aborts if the file is missing.
- **Log pull key**: on the first run the Vagrantfile creates `.vagrant/logpull_ed25519` with `ssh-keygen`. The
  public half goes to every VM as `LOGPULL_PUBKEY`; the private half only to the History VM, base64-encoded into
  one line as `LOGPULL_KEY_B64`. `LOG_SOURCES` (`name=ip` of every VM except History and the bastion) and `LOG_RETENTION_DAYS`
  (default 7) are built there too. See [Logs](#logs).
- The root `.env` is not synced either: the Vagrantfile reads it on the host and passes the values as env vars.
- **Bridged network** (`lan: true`): `BRIDGE_IF` from `.env` (e.g. `wlp4s0`, list with `ip -br link`); if empty,
  Vagrant asks which interface to bridge.
- **`show-lan-ip`** provisioner (`run: "always"`): the DHCP address can change between boots, so it prints
  `<vm> LAN URL: http://<ip>:4173` (the bastion: `<vm> LAN SSH: ssh vagrant@<ip>`) on every `up`/`reload`. It skips the NAT and internal
  (`192.168.56.x`) addresses; what is left is the LAN one.

## provision/common.sh

Shared helpers, sourced first by every per-VM script. A `file` provisioner uploads it to `/tmp/weather-common.sh`
right before the VM's own script (which Vagrant uploads itself), so no VM sees the other VMs' scripts.

- `set -euo pipefail`: `-e` stops on the first error, `-u` makes an unset variable an error,
  `-o pipefail` makes a pipe fail if any command in it fails (not only the last one).
- `DEBIAN_FRONTEND=noninteractive`: apt asks no questions.
- `base_setup`: `apt-get update -qq` (`-qq` = no output) and the packages needed to add the Docker repository;
  writes the `SSH_PUBKEY` line into `authorized_keys` (with `from="<BASTION_IP>"` if `BASTION_IP` is set). The line
  is replaced, not appended, so a re-provisioning adds or removes the restriction; other keys (Vagrant's own) stay.
- `install_docker`: Docker CE and the buildx plugin from Docker's apt repository (bookworm's `docker.io` is old
  and has no buildx, which the Dockerfiles need for BuildKit cache mounts). Skipped if `docker` is installed.
  It also:
  - writes `/etc/docker/daemon.json`: the `journald` log driver (container output goes to the VM's journal with
    `CONTAINER_NAME` and the container name as `SYSLOG_IDENTIFIER`, `docker logs` still works; see [Logs](#logs))
    and `live-restore` (containers keep running while the daemon restarts). Docker is restarted only if the file
    changed, and all containers are removed first: provisioning recreates them anyway, and a container that
    `live-restore` brings back in the middle of a restart (e.g. a Fetcher in its restart loop) can get stuck so
    that `docker rm -f` fails with "did not receive an exit event";
  - adds `vagrant` to the `docker` group, so `docker` works without `sudo` after `vagrant ssh`;
  - creates `ENV_DIR=/etc/weather` (`root:docker`, 0750).
- `write_env <name>`: reads `KEY=VALUE` lines from stdin into `$ENV_DIR/<name>.env` (mode 0640, group `docker`),
  used with `docker run --env-file`. Values go through a heredoc, so secrets are never command-line arguments.
  `--env-file` takes everything after `=` literally, so values are not quoted.
- `write_conf <path> <mode> [owner]`: the same for a config file that is mounted into a container. The owner is
  the uid of the user inside the container when the file holds a secret (redis 999, rabbitmq 100).
- `build_image <name>`: `docker build -t weather/<name> /vagrant/<name>`, then
  `docker image prune -f` to drop the layers the new build replaced. A failed build is retried up to 3 times:
  the VirtualBox NAT DNS (`10.0.2.3`) sometimes fails a lookup when `apk`/`npm` resolve in parallel build stages
  ("DNS: transient error"), and the retry reuses every step that already succeeded from the cache.
- `run_container <name> <docker run args…>`: removes the old container (`docker rm -f`) and starts a new one with
  `--restart unless-stopped` and `--env-file /etc/weather/<name>.env`. Re-provisioning therefore always applies the
  current image and env file; data lives in named volumes and survives. The arguments are also saved (shell-quoted)
  to `/etc/weather/<name>.run`, so `weather-backend` can recreate the container exactly the same way.
- `save_run <name> <docker run args…>`: only saves the arguments to `/etc/weather/<name>.run` (the DB VM uses it for
  the containers of the mode that is not running).
- `install_backend_switch <container…>`: installs `/usr/local/bin/weather-backend` for these containers (Fetcher and History VMs), see
  [Switching the backend at run time](#switching-the-backend-at-run-time).
- `ensure_network <name>`: creates a Docker network if it does not exist yet.
- `wait_healthy <name>`: waits up to 2 minutes until the container's healthcheck reports `healthy`.
- `psql_as_postgres <db>`: runs the SQL from stdin in the `postgres` container as `postgres` (over the socket, `trust`),
  stopping at the first error, so a password in the SQL never shows up in argv.
- `setup_journald`, `setup_log_export`, `setup_log_pull`, `install_timer`: log collection, see [Logs](#logs).

## provision/db.sh (weather-postgres-db)

Prepares both modes and then starts one, so a later switch needs neither provisioning nor a build:

- writes the config files of all three services (table below) and the two SQL files of the switch;
- builds `weather/postgres` (see [Images](#images)) in both modes; `postgres:16-alpine` is pulled on first use;
- saves the `docker run` arguments of `postgres-plain` (`postgres:16-alpine`), `postgres-pgmq` (`weather/postgres`
  with the pg_cron settings, see [PostgreSQL](#postgresql)), `redis` and `rabbitmq` to `/etc/weather/<name>.run`
  (`save_run`), without starting anything;
- installs the DB version of `weather-backend` and runs `weather-backend $USE_REDIS_RABBITMQ`.

`weather-backend` on this VM:

| | `true` | `false` |
|---|---|---|
| `postgres` | recreated from `postgres:16-alpine`; then `sql/pgmq-cleanup.sql` | recreated from `weather/postgres`; then `sql/pgmq-setup.sql` |
| `redis`, `rabbitmq` | recreated (started) | removed (their volumes stay) |

- `pgmq-cleanup.sql` makes the database plain again: `DROP EXTENSION pg_cron, pgmq`, `DROP SCHEMA pgmq, cron`
  (the queue tables come from `pgmq.create()`, not from the extension, so dropping the extension leaves them),
  `DROP TABLE cache_entries`, `DROP EXTENSION hstore` (without `CASCADE`), `DROP OWNED BY fetcher` and `DROP ROLE fetcher`. The weather data in `public` stays.
  It works on the plain image although the extension files are missing there. To keep the queues and the cache
  across switches instead, leave out this step.
- `pgmq-setup.sql` (idempotent): the role `fetcher` (`LOGIN`, password `FETCHER_DB_PASSWORD`, set again every time),
  the pgmq and hstore extensions and both queues, `USAGE` on schema `pgmq` plus `SELECT, INSERT, UPDATE, DELETE` on
  `pgmq.q_weather_fetch_requests` and `pgmq.q_weather_fetch_replies` only, so `fetcher` has no access to
  `weather_observations`. The queues exist before the Fetcher switches, so it does not wait for History. History
  creates pg_cron, hstore, `cache_entries` and the cron job itself on start.
- It waits for the postgres healthcheck and retries the SQL a few times (the first start of an empty volume
  restarts PostgreSQL once after init), and records the mode in `/etc/weather/backend`.

It also installs `/usr/local/bin/redis-cli`, a wrapper that runs `redis-cli` inside the `redis` container
(`docker exec`, with `-t` only on a terminal, so it works in pipes too). It is authenticated through
`REDISCLI_AUTH` from `redis.env`, and `vagrant` is in the `docker` group, so neither a password nor `sudo` is
needed. With `false` it says that the container is not running.

Writes, into `/etc/weather/`:

| File | For | Contents |
|---|---|---|
| `postgres.env` | postgres | `POSTGRES_PASSWORD`, `POSTGRES_DB`: on the first start (empty volume) the image sets the password and creates the database |
| `pg_hba.conf` | postgres | `local all all trust` (socket inside the container, used by `pg_isready`, init and `psql_as_postgres`) and `host all postgres 192.168.56.12/32 scram-sha-256`: only the History VM, with a password. Also `host weather fetcher 192.168.56.11/32 scram-sha-256`: the Fetcher VM, only as `fetcher` and only into the app database (in both modes; with `true` the role does not exist, so the line lets nobody in) |
| `redis.conf` | redis | `requirepass`, `appendonly yes` (data survives restarts), `maxmemory 64mb` with `volatile-lru`; `bind 0.0.0.0` inside the container, the `-p` binding limits it to the DB IP. 0640, owner uid 999, because of the password |
| `redis.env` | redis | `REDISCLI_AUTH`, so the healthcheck's `redis-cli` authenticates without the password in argv |
| `rabbitmq.env` | rabbitmq | `RABBITMQ_DEFAULT_USER/PASS/VHOST`: vhost `weather` and user `weather` (tag `administrator`) are created on the first start, and `guest` is not created at all. `RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS`: see [RabbitMQ](#rabbitmq) |
| `rabbitmq/20-weather.conf` | rabbitmq | `vm_memory_high_watermark.absolute = 256MiB` |
| `rabbitmq/enabled_plugins` | rabbitmq | `rabbitmq_management` (UI on :15672) and `rabbitmq_tracing` |
| `rabbitmq/advanced.config` | rabbitmq | credentials for the tracing plugin (Admin → Tracing in the UI): it reads the queues as a regular user, by default `guest`, which does not exist here. Erlang terms, hence advanced.config; 0640, owner uid 100 |

The `administrator` tag opens the Admin tab (needed for Tracing), which makes `weather` a full broker admin: fine
for a demo. The PostgreSQL and RabbitMQ settings from the env files apply only when the data volume is empty; to
change a password later, change it inside the running service or remove the volume.

## provision/fetcher.sh, history.sh, frontend.sh

| File | Contents |
|---|---|
| `fetcher.env` | `USE_REDIS_RABBITMQ`; `AMQP_URL` and `DATABASE_URL` as `fetcher` (both on the DB VM, the flag picks one); `OPEN_METEO_BASE_URL` |
| `history.env` | `PORT`, `USE_REDIS_RABBITMQ`, `DATABASE_URL`, `AMQP_URL`, `REDIS_URL` (all on the DB VM), `TRIGGER_TOKEN` |
| `scheduler.env` | `HISTORY_SERVICE_URL=http://history:3001` (container name on the `weather` network), `CRON_SCHEDULE`, `TRIGGER_TOKEN` |
| `frontend.env` | `HISTORY_URL=http://192.168.56.12:3001`, the nginx `/api` proxy target |

Passwords are inserted into URLs as they are, so they must not contain URL special characters (`@ : / # %`);
`FETCHER_DB_PASSWORD` also goes into SQL as a literal, so no `'` either.
The env file wins over any `.env`, because dotenv (Node) and the Fetcher never override variables that are already
set; the images do not contain `.env` files anyway.

## Containers

Each per-VM script ends with the containers of that VM; the full `docker run` arguments are in the scripts.

| VM (script) | Order | Image | Publish | Notes |
|---|---|---|---|---|
| DB ([db.sh](../provision/db.sh)) | 1 | `postgres:16-alpine` (`true`) or `weather/postgres` (`false`, built on the VM) | `DB_IP:POSTGRES_PORT` | volume `pgdata`, mounted `pg_hba.conf`, tuning `-c …`, with `false` also pg_cron (see [PostgreSQL](#postgresql)) |
| | 2 | `redis:7-alpine` | `DB_IP:REDIS_PORT` | `true` only; volume `redisdata`, mounted `redis.conf`, `--user redis` |
| | 3 | `rabbitmq:4.1-management-alpine` | `DB_IP:RABBITMQ_PORT`, `DB_IP:RABBITMQ_UI_PORT` | `true` only; volume `rabbitmqdata`, mounted `rabbitmq/*`, `--hostname rabbitmq` |
| Fetcher ([fetcher.sh](../provision/fetcher.sh)) | 1 | `weather/fetcher` | — | built on the VM |
| History ([history.sh](../provision/history.sh)) | 1 | `weather/history` | `HISTORY_IP:HISTORY_PORT` | network `weather` |
| | 2 | `weather/scheduler` | — | network `weather`, calls `http://history:<port>`; its first call 3 s after start may come before History is up, it is logged and the next run follows the schedule |
| Frontend ([frontend.sh](../provision/frontend.sh)) | 1 | `weather/frontend` | `FRONTEND_PORT` → 8080, all interfaces | nginx; tmpfs for its runtime dirs |

The VMs are provisioned in the order of `VMS` (DB first), but nothing depends on that: a service whose dependency on
another VM is down exits or retries until it comes up.

What the flags do:

- `--restart unless-stopped`: Docker restarts the container whenever it exits (the Fetcher exits on a lost
  RabbitMQ connection) and starts it again on boot, unless it was stopped by hand. No service waits for another
  VM: a container whose dependency is down exits or retries until it comes up.
- `-p <ip>:<port>:<port>`: publish on the internal IP only (the frontend on all interfaces, for the LAN).
- `--init` (Node): tini runs as PID 1, forwards SIGTERM and reaps zombies; the Node code has no signal handlers.
- `--read-only` + `--tmpfs`: the container's filesystem is read-only, only volumes and tmpfs are writable. nginx
  renders its config from a template into `/etc/nginx/conf.d` at start, so that tmpfs belongs to its uid 101.
- `--cap-drop ALL`, `no-new-privileges`: no Linux capabilities and no setuid escalation. Postgres and RabbitMQ keep
  their capabilities, because their entrypoints `chown` the data directory and switch user.
- `--memory`: hard limits that fit the 1 GB VMs (the three on the DB VM add up to ~800 MB of 1536).
- `--hostname rabbitmq`: RabbitMQ stores data per node name (`rabbit@<hostname>`); a fixed name keeps the volume
  usable after the container is recreated.

### Switching the backend at run time

Every image both modes need is already on the VMs, and every env file and `docker run` argument list is already
written, so a switch only starts other containers from existing images. `weather-backend` is installed on the DB,
Fetcher and History VMs; run it on all three, DB first:

```bash
for vm in weather-postgres-db weather-fetcher weather-history; do
  vagrant ssh $vm -c "weather-backend false"             # false: PostgreSQL + pgmq + pg_cron, true: Redis + RabbitMQ
done
vagrant ssh weather-history -c "weather-backend"         # show the current value (no change)
```

- On the DB VM it swaps the containers as described in [provision/db.sh](#provisiondbsh-weather-postgres-db).
- On the Fetcher and History VMs the env files hold the URLs of both backends and only the `USE_REDIS_RABBITMQ`
  line differs. Docker reads `--env-file` only when a container is created (`docker restart` keeps the old value),
  so `weather-backend` changes the line in `/etc/weather/<name>.env` and recreates the container from the image it
  was running, with the arguments saved in `<name>.run` (`install_backend_switch`).

No apt, no build; about 20 s for all three (most of it waiting for PostgreSQL). It calls `sudo` itself (the env files
belong to root). While the VMs are switched one after another, fetches answer 502 and History reconnects to the
restarted PostgreSQL by itself. Requests in the old queues expire (20 s), and saved themes are not copied between
Redis and `cache_entries`, so the UI falls back to the system theme once.

`USE_REDIS_RABBITMQ` in the root `.env` is the value provisioning writes, so the next `vagrant provision` of these
VMs sets it back to `.env`; change it there too to keep a switch.

**After a code or `.env` change**: `vagrant provision <vm>` rebuilds that VM's images and recreates its containers.
Data stays in the named volumes (`pgdata`, `redisdata`, `rabbitmqdata`). `docker stop <name>` keeps a container
stopped across reboots (that is the "unless-stopped" part) until `docker start <name>` or the next provisioning.

## Images

Each image is built with its own service directory as the build context. `history/`, `scheduler/` and `frontend/`
have their own `package-lock.json` with only their dependencies, so the root workspace `package.json` and
`package-lock.json` (local development only) are not needed. Each `Dockerfile.dockerignore` allows only the files
the image needs, so the local `node_modules`, `dist` and `.env` never reach the build.

The service lockfiles are separate from the root one: after changing a service's dependencies, regenerate its
lockfile outside the workspace (inside it npm uses the root lockfile), e.g.
`d=$(mktemp -d) && cp history/package.json $d && (cd $d && npm install --package-lock-only) && cp $d/package-lock.json history/`.

Common to all: multi-stage builds (compilers and npm stay in the build stage), dependency manifests copied before
the code (the dependency layer is cached until they change), BuildKit cache mounts for npm and Go (fast rebuilds),
a non-root user, secrets only at run time.

| Image | Build | Runtime | Size |
|---|---|---|---|
| `weather/postgres` | `postgres:16-alpine` + `build-base`: pgmq (plain SQL) and pg_cron (C, `make with_llvm=no`: the alpine image is built with JIT, and without it PGXS wants clang for bitcode) from release tarballs, versions as build args | `postgres:16-alpine` + only the extension files and `pg_cron.so` | ~295 MB (the base image is ~290 MB) |
| `weather/fetcher` | `golang:1.22-alpine`, `CGO_ENABLED=0`, `-trimpath -ldflags="-s -w"` | `distroless/static-debian12:nonroot`: no shell or libc, but CA certificates (HTTPS to Open-Meteo) and tzdata | ~20 MB |
| `weather/history` | `node:22-alpine3.24`, `npm ci --omit=dev`; `.ts`, `.map`, `.md` files removed from `node_modules`; `node` binary stripped | `alpine:3.24` + `libstdc++` + the `node` binary only (no npm, yarn, corepack). No healthcheck: check it with `curl …/api/health` | ~140 MB |
| `weather/scheduler` | same | same | ~125 MB |
| `weather/frontend` | `node:22-alpine3.24`, `vite build`, then `gzip -9` copies of js/css/html/svg | `nginx-unprivileged:1.27-alpine-slim` (port 8080, uid 101) | ~13 MB |

The Node images are dominated by the `node` binary itself (~114 MB after `strip`); a stock `node:22-alpine` with the
same dependencies would be ~215 MB. The runtime Alpine version must match the one of the Node build image.

**Frontend (nginx)**: built without `VITE_API_URL`, so the browser calls the relative `/api` on the host:port it
opened and the UI works from any device in the LAN. nginx serves `dist/` and proxies `/api/` to `HISTORY_URL`
(filled in from the env at start), so the `uid` cookie used by `/api/preferences` stays same-origin. Hashed files in
`/assets/` are cached for a year (`immutable`), `index.html` is `no-cache`, `gzip_static` serves the pre-compressed
files, unknown paths fall back to `index.html`, and `/healthz` is the healthcheck.

### PostgreSQL

`postgres:16-alpine` with `true`, `weather/postgres` (the same plus pgmq and pg_cron) with `false`; both use the
volume `pgdata`. `hba_file` points at the mounted `pg_hba.conf`. Tuned for a small VM: `shared_buffers=64MB`,
`effective_cache_size=192MB`, `max_connections=30`, `--shm-size 128m`.
With `false` also `shared_preload_libraries=pg_cron` (it must be loaded at server start), `cron.database_name=<POSTGRES_DB>`
and `cron.host=/var/run/postgresql`. pg_cron runs each job over a client connection, by default TCP to `localhost`
(`::1` in the container), which `pg_hba.conf` does not allow; over the socket the existing `local all all trust`
line lets it in. Runs and errors: `cron.job_run_details`. History creates the `weather` database if it
is missing (`ensureDatabase()`), so a reused volume works too. With `false` the connections are History's Sequelize
pool (5) and broker pool (3) and the Fetcher's pool (5), well under 30.

### RabbitMQ

`rabbitmq:4.1-management-alpine`. `vm_memory_high_watermark.absolute` keeps it under its 384 MB limit (the default
is a fraction of the VM's RAM, not of the container's). `+S 1:1 +sbwt none +sbwtdcpu none +sbwtdio none` runs one
Erlang scheduler and turns off scheduler busy-waiting, so an idle broker on a 1-CPU VM uses almost no CPU.

## Logs

Logs of all VMs are collected on `weather-history`. History **pulls** them; the other VMs never connect to it.

```
db / fetcher / frontend                                    weather-history
journald (system + containers, 7 days)                     weather-log-pull.timer (:05, :20, :35, :50)
  │ weather-log-export.timer (:00, :15, :30, :45)            rsync over SSH as logpull  ◀── pull
  ▼ journalctl --cursor-file -o export | zstd                → /var/log/weather-remote/<vm>/*.export.zst
/var/log/weather-export/<host>-<UTC time>.export.zst         zstdcat | systemd-journal-remote
                                                             → /var/log/journal/remote/<vm>-<YYYYMMDD>.journal
```

- **journald** (`setup_journald`, all VMs): `/etc/systemd/journald.conf.d/50-weather.conf` with
  `Storage=persistent`, `MaxRetentionSec=<LOG_RETENTION_DAYS>day`, `SystemMaxUse=200M`. Containers log into it
  through the Docker `journald` driver.
- **Export** (`setup_log_export`, every VM except History and the bastion): every 15 minutes `weather-log-export` writes the
  entries since the last run (`--cursor-file`, so nothing is exported twice or skipped) in journal export format,
  compressed with zstd. The file is written under `/var/lib/weather-logs` and moved into
  `/var/log/weather-export` only when it is complete, so a pull never sees a half-written file. Runs with no new
  entries produce no file.
- **Access**: the system user `logpull` accepts only the pull key, and `authorized_keys` restricts it:
  `restrict` (no pty or forwarding), `from="<HISTORY_IP>"` (only the History VM) and
  `command="/usr/local/sbin/weather-log-serve"`. That forced command runs instead of whatever the client asks for:
  it accepts only the command an rsync download sends (`rsync --server --sender -<short flags> . .`), refuses
  anything else (a shell command, a write, a long option such as `--remove-source-files`, another path) and runs
  `rsync --server --sender` on `/var/log/weather-export` itself. In `--sender` mode rsync only reads, so the key
  cannot change anything on the VM. (This replaces `rrsync -ro`, which is a Python script and would need `python3`.)
- **Pull** (`setup_log_pull`, History): 5 minutes after each export `weather-log-pull` fetches the new archives
  from every VM in `/etc/weather/log-sources` (`rsync --ignore-existing`) and imports each one once (list in
  `/var/lib/weather-logs/imported`) into a journal file per VM and day. On import `_HOSTNAME` is set to the VM
  name: entries from a VM's first boot would otherwise carry the box's hostname `bookworm` (Vagrant renames the
  VM only after it has started). A VM that is down is logged and skipped;
  its archives are fetched on the next run. The `systemd-journal-remote` package is used only for its binary, its
  network socket (port 19532) is disabled. Host keys are trusted on first use and forgotten on every
  `vagrant provision weather-history` (after re-creating a source VM, re-provision History).
- **Retention**: `LOG_RETENTION_DAYS` (default 7) everywhere: journald on each VM, and `systemd-tmpfiles`
  (`e` lines in `/etc/tmpfiles.d/weather-log-*.conf`, run daily by `systemd-tmpfiles-clean.timer`) for
  `/var/log/weather-export` on the sources and `/var/log/weather-remote` and `/var/log/journal/remote` on History.

```bash
vagrant ssh weather-history
sudo journalctl -D /var/log/journal/remote _HOSTNAME=weather-fetcher --since -1h   # one VM
sudo journalctl -D /var/log/journal/remote CONTAINER_NAME=postgres -f -n 20       # one container
sudo journalctl -m -p warning --since today                                       # all VMs incl. History
sudo systemctl start weather-log-pull && journalctl -u weather-log-pull -n 20     # pull now
systemctl list-timers 'weather-log-*'
```

## Bastion

`weather-bastion` (192.168.56.14, 512 MB) is the SSH entry point. It is bridged into the LAN like the frontend
and runs no services: [provision/bastion.sh](../provision/bastion.sh) only calls `base_setup`. No Docker, no
synced folders, no log export.

```
host / LAN device ──ssh──▶ weather-bastion (LAN IP) ──ssh over intnet──▶ 192.168.56.10–13
```

- The other VMs accept `SSH_PUBKEY` only from `192.168.56.14` (`from=` in `authorized_keys`), and the host
  cannot reach 192.168.56.x at all (internal network), so there is no direct path from the host or the LAN.
- The private key stays on the host: use `ProxyJump` (`ssh -J`), which tunnels the second connection through the
  bastion (`ssh -W`, allowed by Debian's default `AllowTcpForwarding yes`). The bastion holds no keys and needs no
  agent forwarding.
- `vagrant ssh` is not affected: it uses Vagrant's own key through the NAT port forward.
- The LAN address comes from DHCP and is printed on every `up`/`reload` (`weather-bastion LAN SSH: ssh vagrant@<ip>`);
  reserve it on the router (by MAC) to keep `~/.ssh/config` stable. If the host cannot reach its own bridged VM
  (common on Wi-Fi), the only way in from the host is `vagrant ssh`; then give the bastion a host-only adapter
  as well (a second `private_network` without `virtualbox__intnet`).
- After re-creating a VM its host key changes: `ssh-keygen -R <ip>`.

Example `~/.ssh/config`:

```
Host weather-bastion
  HostName <LAN IP of the bastion>
  User vagrant
  IdentityFile ~/.ssh/id_ed25519
Host weather-postgres-db weather-fetcher weather-history weather-frontend
  User vagrant
  IdentityFile ~/.ssh/id_ed25519
  ProxyJump weather-bastion
Host weather-postgres-db
  HostName 192.168.56.10
Host weather-fetcher
  HostName 192.168.56.11
Host weather-history
  HostName 192.168.56.12
Host weather-frontend
  HostName 192.168.56.13
```

Services on the internal network (History API, RabbitMQ UI, PostgreSQL) are reached from the host through an SSH
tunnel over the bastion, e.g. `ssh -N -L 15672:192.168.56.10:15672 weather-bastion`, then http://localhost:15672.

`vagrant ssh` (Vagrant's NAT port forward `127.0.0.1:2222` → VM:22) stays a path from the host to every VM's sshd;
`from=` limits only the key, so if the box allows password logins (`vagrant`/`vagrant`), that path accepts them.

## Useful commands

```bash
ssh -N -L 15672:192.168.56.10:15672 weather-bastion   # management UI: http://localhost:15672  (weather / RABBITMQ_PASSWORD)
vagrant ssh weather-postgres-db -c "docker exec rabbitmq rabbitmqctl list_queues -p weather name messages consumers"
vagrant ssh weather-postgres-db -c "docker exec -it postgres psql -U postgres weather"
vagrant ssh weather-postgres-db -c "redis-cli --scan --pattern 'preferences:*'"   # cache keys; also: redis-cli get <key>, ttl <key>
vagrant ssh weather-postgres-db -- -t redis-cli                                    # interactive
vagrant ssh weather-postgres-db -c "docker exec postgres psql -U postgres weather -c 'select * from pgmq.metrics_all()'"
vagrant ssh weather-postgres-db -c "docker exec postgres psql -U postgres weather -c 'select * from cron.job_run_details order by runid desc limit 3'"
vagrant ssh weather-history -c "docker ps"
vagrant ssh weather-history -c "docker logs --tail 50 history"
vagrant ssh weather-history -c "sudo cat /etc/weather/scheduler.env"
vagrant ssh weather-history -c "curl -s http://192.168.56.12:3001/api/health"
vagrant reload weather-frontend --provision   # prints "weather-frontend LAN URL: http://<ip>:4173"
```
