# Infrastructure (Vagrant + provisioning)

How the [Vagrantfile](../Vagrantfile) and the scripts in [provision/](../provision/) build the four VMs.
The code itself has no comments; this file explains it.

## Commands

```bash
vagrant up                                   # all VMs
vagrant up weather-history                   # a single VM
vagrant provision <vm>                       # re-sync sources, rebuild, restart services
vagrant reload weather-frontend --provision  # needed after network/RAM changes (e.g. a new adapter)
vagrant ssh <vm> -c "systemctl status <unit>"
```

## Topology

| VM | Host-only IP | Services (systemd units) |
|---|---|---|
| `weather-postgres-db` | 192.168.56.10 | `postgresql`, `redis-server`, `rabbitmq-server` (management UI :15672) |
| `weather-fetcher` | 192.168.56.11 | `weather-fetcher` (no HTTP port, RabbitMQ worker) |
| `weather-history` | 192.168.56.12 | `weather-history` (:3001), `weather-scheduler` |
| `weather-frontend` | 192.168.56.13 + LAN (DHCP) | `weather-frontend` (`vite preview`, :4173) |

## Vagrantfile

- **Secrets** live in the (gitignored) root `.env`, never in the Vagrantfile. It is parsed as `KEY=VALUE` lines
  (no quotes: everything after the first `=` is the value). `POSTGRES_PASSWORD`, `REDIS_PASSWORD` and
  `RABBITMQ_PASSWORD` are required; `vagrant up` aborts with "Set … in .env" if one is empty.
- **`VMS`**: one entry per VM; add a line here to add a machine.
  - `ip`, `memory`, `cpus` (default 1);
  - `folders`: host dirs synced to `/vagrant_src/<dir>`;
  - `script`: provisioning for that VM's services (from `provision/`);
  - `lan: true`: also bridge the VM into the host's LAN (DHCP from the router) so other devices can reach it.
- **`PROVISION_ENV`** is passed to every provisioning script: where each service lives (`DB_IP`, `HISTORY_IP`)
  plus secrets and settings from the host `.env` (`POSTGRES_DB`, `TRIGGER_TOKEN`, `CRON_SCHEDULE`, …).
  `setting.(key, default)` takes a value from `.env` and falls back to the default if it is missing or empty.
- **Ports** are settings too, so each is defined in one place and every script that needs it (the service
  itself and its clients) gets the same value:

  | `.env` key | Default | Used by |
  |---|---|---|
  | `HISTORY_PORT` | 3001 | History; the scheduler's URL; the frontend proxy target |
  | `FRONTEND_PORT` | 4173 | `vite preview`; the `show-lan-ip` URL |
  | `POSTGRES_PORT` | 5432 | PostgreSQL (`port` in postgresql.conf); `DATABASE_URL` (also used by docker-compose locally) |
  | `REDIS_PORT` | 6379 | Redis (`port` in weather.conf); `REDIS_URL` |
  | `RABBITMQ_PORT` | 5672 | RabbitMQ AMQP listener; `AMQP_URL` of History and Fetcher |
  | `RABBITMQ_UI_PORT` | 15672 | RabbitMQ management UI |

  After changing a port, re-provision the VM that runs the service and the VMs of its clients, e.g. for
  `REDIS_PORT`: `vagrant provision weather-postgres-db weather-history`.
- The project root is synced to `/vagrant` on every VM, so the scripts can `source /vagrant/provision/common.sh`.
- **Bridged network** (`lan: true`): `BRIDGE_IF` from `.env` (e.g. `wlp4s0`, list with `ip -br link`); if empty,
  Vagrant asks which interface to bridge.
- **`show-lan-ip`** provisioner (`run: "always"`): the DHCP address can change between boots, so it prints
  `<vm> LAN URL: http://<ip>:4173` on every `up`/`reload`. It skips the NAT (`10.0.2.x`) and host-only
  (`192.168.56.x`) addresses; what is left is the LAN one.

## provision/common.sh

Shared helpers, sourced first by every per-VM script.

- `set -euo pipefail`: `-e` stops on the first error, `-u` makes an unset variable an error,
  `-o pipefail` makes a pipe fail if any command in it fails (not only the last one).
- `DEBIAN_FRONTEND=noninteractive`: apt asks no questions.
- Directories:
  - `SRC_DIR=/vagrant_src`: synced folders from the host;
  - `APP_DIR=/opt/weather`: working copies the services run from;
  - `ENV_DIR=/etc/weather`: per-service env files (root and group `weather` only, they hold secrets).
- `base_setup`: `apt-get update -qq` (`-qq` = no output), base packages, the system user `weather`
  (no login shell), and the directories above (`install -d` does not fail if the directory exists).
- `install_node`: Node 22 from NodeSource, skipped if `node` is already installed.
- `sync_src <name>`: copies a synced folder into `$APP_DIR`, leaving out host-only artifacts
  (`node_modules`, `.env`, `bin`, `dist`). Leaving out `.env` means the `localhost` values from local
  development never reach the VMs.
- `write_env <name>`: reads `KEY=VALUE` lines from stdin into `$ENV_DIR/<name>.env` (mode 0640). Values go through
  a heredoc, so secrets are never command-line arguments.
- `install_unit <name> <workdir> <exec-start> [description]`: one systemd unit per service. It starts on boot
  (`WantedBy=multi-user.target`), restarts on any exit (`Restart=always`, `RestartSec=3`,
  `StartLimitIntervalSec=0` so systemd never gives up) and has no inter-VM dependencies: a service whose
  dependency is down just exits and is restarted until it comes up. The env file (`EnvironmentFile=`) wins over
  any `.env`, because dotenv (Node) and the Fetcher never override variables that are already set.

## provision/db.sh (weather-postgres-db)

**PostgreSQL**
- Listens on the LAN address only (`listen_addresses = 192.168.56.10`) and accepts only the History VM, with
  password auth (`pg_hba.conf`: `host all postgres 192.168.56.12/32 scram-sha-256`). Lines marked
  `# weather-managed` are removed and re-added on each run, so re-provisioning does not duplicate them.
- The password reaches `psql` through the environment (not argv), so it is not visible in `ps`; `:'pw'` quotes
  it safely as an SQL literal.
- The `weather` database is created if it does not exist.

**Redis** (cache for UI preferences)
- Our settings live in a separate file, `/etc/redis/weather.conf`, included last so they win over the defaults
  in `redis.conf`; mode 0640 `root:redis` because it holds the password.
- `bind 192.168.56.10`, `requirepass`, `appendonly yes` (data survives restarts), `maxmemory 64mb` with
  `volatile-lru`.
- `redis.conf` does not allow trailing comments, so the `include` line is matched exactly to keep
  re-provisioning idempotent.

**RabbitMQ** (request/reply queues between History and Fetcher)
- AMQP (`:5672`) and the management UI (`:15672`) listen on the LAN address only; `guest` may log in from
  localhost only, and is deleted anyway.
- The tracing plugin (Admin → Tracing in the UI) records copies of the messages for debugging. It reads the
  queues as a regular user, by default `guest` (which is deleted), so it gets the `weather` credentials in
  `/etc/rabbitmq/advanced.config` (Erlang terms, hence advanced.config; 0640 because of the password).
- vhost `weather` with user `weather`, who has rights on that vhost only. The `administrator` tag opens the
  Admin tab (needed for Tracing), which makes `weather` a full broker admin: fine for a demo.
- `rabbitmqctl` takes the password as an argument, so it is briefly visible in `ps` while provisioning;
  acceptable for this demo VM.

```bash
# management UI: http://192.168.56.10:15672  (weather / RABBITMQ_PASSWORD)
vagrant ssh weather-postgres-db -c "sudo rabbitmqctl list_queues -p weather name messages consumers"
vagrant ssh weather-postgres-db -c "sudo -u postgres psql weather"
vagrant ssh weather-postgres-db -c "systemctl is-active postgresql redis-server rabbitmq-server"
```

## provision/fetcher.sh (weather-fetcher)

- `GO_VERSION` (default 1.22.12) is installed from go.dev, because the `golang` package in Debian bookworm is
  too old for `go.mod`. Skipped if that version is already in `/usr/local/go`.
- The binary is compiled here, at provisioning time (`go build` also downloads the modules).
- No HTTP port: the Fetcher only talks to RabbitMQ (requests in, replies out). Env: `AMQP_URL`,
  `OPEN_METEO_BASE_URL`. If the connection to RabbitMQ is lost, the process exits and systemd restarts it.

## provision/history.sh (weather-history)

- History and the scheduler each get `npm install --omit=dev` in their own folder.
- `weather-history.env`: `PORT`, `DATABASE_URL`, `AMQP_URL`, `REDIS_URL`, all pointing at the DB VM.
- `weather-scheduler.env`: `HISTORY_SERVICE_URL` (the VM's own LAN IP, not 127.0.0.1) and `CRON_SCHEDULE`.
- Passwords are inserted into URLs as they are, so they must not contain URL special characters
  (`@ : / # %`).

```bash
vagrant ssh weather-history -c "systemctl status weather-history weather-scheduler"
vagrant ssh weather-history -c "sudo journalctl -u weather-history -n 50"
vagrant ssh weather-history -c "sudo cat /etc/weather/weather-scheduler.env"
```

## provision/frontend.sh (weather-frontend)

- Built without `VITE_API_URL`: the browser calls the relative `/api` on the same host:port it opened, so it
  works from any device in the LAN; `vite preview` proxies `/api` to History over the host-only network.
- `VITE_PROXY_TARGET` is read by `vite.config.js` (`loadEnv` also picks up `VITE_*` variables from the process
  environment, i.e. from the systemd env file).
- `vite preview --host 0.0.0.0` listens on both the host-only and the bridged interface.

```bash
vagrant reload weather-frontend --provision   # prints "weather-frontend LAN URL: http://<ip>:4173"
```
