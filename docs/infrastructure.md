# Infrastructure (Vagrant + Docker)

How the [Vagrantfile](../Vagrantfile) and the scripts in [provision/](../provision/) build the four VMs and run the
services on them as Docker containers. The code itself has no comments; this file explains it.

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

| VM | Host-only IP | Containers | Published ports |
|---|---|---|---|
| `weather-postgres-db` | 192.168.56.10 | `postgres`, `redis`, `rabbitmq` | 5432, 6379, 5672, 15672 on 192.168.56.10 only |
| `weather-fetcher` | 192.168.56.11 | `fetcher` (no port, RabbitMQ worker) | — |
| `weather-history` | 192.168.56.12 | `history`, `scheduler` (Docker network `weather`) | 3001 on 192.168.56.12 only |
| `weather-frontend` | 192.168.56.13 + LAN (DHCP) | `frontend` (nginx, static UI + `/api` proxy) | 4173 → 8080 on all interfaces |

The VMs talk to each other exactly as before: a client uses the other VM's IP and the published port. Docker
publishes a port with DNAT, which keeps the client's source IP, so `pg_hba.conf` can still allow the History
VM only. On the History VM the scheduler reaches History by name (`http://history:3001`) over the user-defined
network `weather`, which has its own DNS.

## Vagrantfile

- **Secrets** live in the (gitignored) root `.env`, never in the Vagrantfile. It is parsed as `KEY=VALUE` lines
  (no quotes: everything after the first `=` is the value). `POSTGRES_PASSWORD`, `REDIS_PASSWORD` and
  `RABBITMQ_PASSWORD` are required; `vagrant up` aborts with "Set … in .env" if one is empty.
- **`VMS`**: one entry per VM; add an entry here to add a machine.
  - `ip`, `memory`, `cpus` (default 1); the DB VM has 1536 MB because it runs three containers;
  - `script`: provisioning for that VM (from `provision/`);
  - `sync`: the service directories mounted on the VM (see *Synced folders*);
  - `env`: the `PROVISION_ENV` keys its script uses;
  - `lan: true`: also bridge the VM into the host's LAN (DHCP from the router) so other devices can reach it.
- **`PROVISION_ENV`** holds everything the provisioning scripts may need: where each service lives (`DB_IP`,
  `HISTORY_IP`) plus secrets and settings from the host `.env` (`POSTGRES_DB`, `TRIGGER_TOKEN`, `CRON_SCHEDULE`, …).
  Each VM gets only its `env` keys plus `SSH_PUBKEY` (`PROVISION_ENV.slice`), so e.g. the frontend VM receives no
  password at all and the fetcher VM only `RABBITMQ_PASSWORD`. A script that starts using a new variable needs it
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
  its own services (`sync:` in `VMS`; the db VM none), mounted read-only
  (`type: "virtualbox"`, `ro`) at `/vagrant/<dir>`. The mounts are live, so `vagrant provision` always builds the
  current code. The VMs never see the root `.env`, `.git` or `.vagrant/` (which holds the private SSH keys of all
  VMs) and cannot write to the host. The local `.env`, `node_modules/`, `dist/` and `bin/` inside a service
  directory are visible on the VM but never reach an image: each `Dockerfile.dockerignore` is an allowlist.
- **SSH key**: `id_ed25519.pub` (gitignored) is read on the host and passed as `SSH_PUBKEY`; `base_setup` adds it
  to `~vagrant/.ssh/authorized_keys`. `vagrant up` aborts if the file is missing.
- The root `.env` is not synced either: the Vagrantfile reads it on the host and passes the values as env vars.
- **Bridged network** (`lan: true`): `BRIDGE_IF` from `.env` (e.g. `wlp4s0`, list with `ip -br link`); if empty,
  Vagrant asks which interface to bridge.
- **`show-lan-ip`** provisioner (`run: "always"`): the DHCP address can change between boots, so it prints
  `<vm> LAN URL: http://<ip>:4173` on every `up`/`reload`. It skips the NAT (`10.0.2.x`) and host-only
  (`192.168.56.x`) addresses; what is left is the LAN one.

## provision/common.sh

Shared helpers, sourced first by every per-VM script. A `file` provisioner uploads it to `/tmp/weather-common.sh`
right before the VM's own script (which Vagrant uploads itself), so no VM sees the other VMs' scripts.

- `set -euo pipefail`: `-e` stops on the first error, `-u` makes an unset variable an error,
  `-o pipefail` makes a pipe fail if any command in it fails (not only the last one).
- `DEBIAN_FRONTEND=noninteractive`: apt asks no questions.
- `base_setup`: `apt-get update -qq` (`-qq` = no output) and the packages needed to add the Docker repository.
- `install_docker`: Docker CE and the buildx plugin from Docker's apt repository (bookworm's `docker.io` is old
  and has no buildx, which the Dockerfiles need for BuildKit cache mounts). Skipped if `docker` is installed.
  It also:
  - writes `/etc/docker/daemon.json`: the `local` log driver with rotation (10 MB × 3 per container, so logs
    cannot fill the disk) and `live-restore` (containers keep running while the daemon restarts). Docker is
    restarted only if the file changed;
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
  current image and env file; data lives in named volumes and survives.
- `ensure_network <name>`: creates a Docker network if it does not exist yet.

## provision/db.sh (weather-postgres-db)

Writes, into `/etc/weather/`:

| File | For | Contents |
|---|---|---|
| `postgres.env` | postgres | `POSTGRES_PASSWORD`, `POSTGRES_DB`: on the first start (empty volume) the image sets the password and creates the database |
| `pg_hba.conf` | postgres | `local all all trust` (socket inside the container, used by `pg_isready` and init) and `host all postgres 192.168.56.12/32 scram-sha-256`: only the History VM, with a password |
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
| `fetcher.env` | `AMQP_URL` (DB VM), `OPEN_METEO_BASE_URL` |
| `history.env` | `PORT`, `DATABASE_URL`, `AMQP_URL`, `REDIS_URL` (all on the DB VM), `TRIGGER_TOKEN` |
| `scheduler.env` | `HISTORY_SERVICE_URL=http://history:3001` (container name on the `weather` network), `CRON_SCHEDULE`, `TRIGGER_TOKEN` |
| `frontend.env` | `HISTORY_URL=http://192.168.56.12:3001`, the nginx `/api` proxy target |

Passwords are inserted into URLs as they are, so they must not contain URL special characters (`@ : / # %`).
The env file wins over any `.env`, because dotenv (Node) and the Fetcher never override variables that are already
set; the images do not contain `.env` files anyway.

## Containers

Each per-VM script ends with the containers of that VM; the full `docker run` arguments are in the scripts.

| VM (script) | Order | Image | Publish | Notes |
|---|---|---|---|---|
| DB ([db.sh](../provision/db.sh)) | 1 | `postgres:16-alpine` | `DB_IP:POSTGRES_PORT` | volume `pgdata`, mounted `pg_hba.conf`, tuning `-c …` (see [PostgreSQL](#postgresql)) |
| | 2 | `redis:7-alpine` | `DB_IP:REDIS_PORT` | volume `redisdata`, mounted `redis.conf`, `--user redis` |
| | 3 | `rabbitmq:4.1-management-alpine` | `DB_IP:RABBITMQ_PORT`, `DB_IP:RABBITMQ_UI_PORT` | volume `rabbitmqdata`, mounted `rabbitmq/*`, `--hostname rabbitmq` |
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
- `-p <ip>:<port>:<port>`: publish on the host-only IP only (the frontend on all interfaces, for the LAN).
- `--init` (Node): tini runs as PID 1, forwards SIGTERM and reaps zombies; the Node code has no signal handlers.
- `--read-only` + `--tmpfs`: the container's filesystem is read-only, only volumes and tmpfs are writable. nginx
  renders its config from a template into `/etc/nginx/conf.d` at start, so that tmpfs belongs to its uid 101.
- `--cap-drop ALL`, `no-new-privileges`: no Linux capabilities and no setuid escalation. Postgres and RabbitMQ keep
  their capabilities, because their entrypoints `chown` the data directory and switch user.
- `--memory`: hard limits that fit the 1 GB VMs (the three on the DB VM add up to ~800 MB of 1536).
- `--hostname rabbitmq`: RabbitMQ stores data per node name (`rabbit@<hostname>`); a fixed name keeps the volume
  usable after the container is recreated.

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
| `weather/fetcher` | `golang:1.22-alpine`, `CGO_ENABLED=0`, `-trimpath -ldflags="-s -w"` | `distroless/static-debian12:nonroot`: no shell or libc, but CA certificates (HTTPS to Open-Meteo) and tzdata | ~8 MB |
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

`postgres:16-alpine`; `hba_file` points at the mounted `pg_hba.conf`. Tuned for a small VM: `shared_buffers=64MB`,
`effective_cache_size=192MB`, `max_connections=30`, `--shm-size 128m`. History creates the `weather` database if it
is missing (`ensureDatabase()`), so a reused volume works too.

### RabbitMQ

`rabbitmq:4.1-management-alpine`. `vm_memory_high_watermark.absolute` keeps it under its 384 MB limit (the default
is a fraction of the VM's RAM, not of the container's). `+S 1:1 +sbwt none +sbwtdcpu none +sbwtdio none` runs one
Erlang scheduler and turns off scheduler busy-waiting, so an idle broker on a 1-CPU VM uses almost no CPU.

## Useful commands

```bash
# management UI: http://192.168.56.10:15672  (weather / RABBITMQ_PASSWORD)
vagrant ssh weather-postgres-db -c "docker exec rabbitmq rabbitmqctl list_queues -p weather name messages consumers"
vagrant ssh weather-postgres-db -c "docker exec -it postgres psql -U postgres weather"
vagrant ssh weather-history -c "docker ps"
vagrant ssh weather-history -c "docker logs --tail 50 history"
vagrant ssh weather-history -c "sudo cat /etc/weather/scheduler.env"
curl http://192.168.56.12:3001/api/health
vagrant reload weather-frontend --provision   # prints "weather-frontend LAN URL: http://<ip>:4173"
```
