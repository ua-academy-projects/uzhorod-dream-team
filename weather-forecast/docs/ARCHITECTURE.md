# Weather Forecast Architecture

This document describes the pre-container architecture. Each service runs
directly on an Ubuntu 24.04 Vagrant VM and is managed by systemd.

## Components

| VM | Address | Ports | Responsibility |
| --- | --- | --- | --- |
| `db` | `192.168.56.11` | 5432, 5672, 6379 | PostgreSQL, RabbitMQ, Redis |
| `fetcher` | `192.168.56.12` | 8001 | Python Fetcher and RabbitMQ worker |
| `history` | `192.168.56.13` | 8002 | Go API, timers, queue consumer, database writer |
| `ui` | `192.168.56.14` | 80 | Nginx and static HTML/CSS/JavaScript |

The UI VM port 80 is forwarded to port 8080 on the Arch host. The browser
therefore uses `http://localhost:8080/` and sends relative `/api/` requests.

## Data flow

The browser sends requests only to Nginx. Nginx serves the static UI and
proxies `/api/` to History. History never calls Fetcher directly.

Current weather follows this path:

```text
browser -> Nginx -> History -> RabbitMQ weather.requests
                                      -> Fetcher -> Open-Meteo
                                      <- RabbitMQ weather.responses
                              History -> PostgreSQL
                              History -> browser
```

History starts a collection when the page requests it, when the user presses
the collection button, and every 15 minutes. A job has a request ID and type.
History stores its state in PostgreSQL, publishes a durable message, and waits
for the Fetcher response. Results are validated before they are stored.

Temperature history uses a second job type. History checks the stored hourly
range at startup and every hour. It requests an initial 30-day backfill or
only missing ranges. Fetcher returns all requested ranges in one response;
History validates and stores the complete response in one transaction.

## Storage

PostgreSQL contains:

- `weather_snapshots` for current weather records;
- `temperature_history` for hourly chart points;
- `weather_jobs` for queued, completed, and failed jobs.

The `(city, weather_time)` key prevents duplicate current-weather rows. A
repeated collection updates the existing row and its `fetched_at` value.

RabbitMQ provides durable `weather.requests` and `weather.responses` queues.
Messages are persistent, publisher confirms are enabled, and consumers use
manual acknowledgements. History acknowledges a response only after the
database transaction succeeds. Fetcher acknowledges a request only after its
response is published successfully.

Redis stores only UI theme preferences. The browser keeps a random
`weather_session` cookie; History uses it as the `session:<id>` Redis key.
The cookie and Redis entry expire after 30 days. Redis failure does not remove
weather data from PostgreSQL.

## Provisioning

`vagrant/Vagrantfile` defines the four VMs, private addresses, resources,
rsync folders, filtered secret files, templates, and role-specific scripts.

The shared `vagrant/common.sh` prepares directories and the `weather` service
user, renders templates, installs systemd units, and configures broker access.
The role scripts install and configure the required software:

- `provision-db.sh` installs PostgreSQL, RabbitMQ, and Redis, then applies SQL
  migrations or performs an explicit import into an empty database;
- `provision-fetcher.sh` creates a Python virtual environment, installs
  dependencies, and starts `weather-fetcher.service`;
- `provision-history.sh` builds the Go binary in the VM and starts
  `weather-history.service`;
- `provision-ui.sh` installs Nginx, copies static files, and configures the
  proxy to History.

Provisioning is repeatable: existing database data and broker credentials are
preserved. Database import is enabled only with `WEATHER_IMPORT_DB=1` and
requires `weather_history.dump` and `weather_history.count` on the DB VM.

## Network and access

The four VMs communicate through the private `192.168.56.0/24` network.
PostgreSQL, RabbitMQ, and Redis listen on the DB VM private address. Fetcher
and History listen on all interfaces inside their VMs so the other services
can reach them.

During the first provisioning, Vagrant uses the stock SSH connection to
bootstrap the VM. Provisioning then installs the public key from
`~/.ssh/weather_vm.pub`, disables password and root SSH login, and switches
the SSH service to `WEATHER_SSH_PORT`. The private key never leaves the Arch
host. The SSH port is passed through configuration and is not stored in the
repository.

Secrets stay in the local `weather-deploy-input/secrets.env`. Vagrant creates
temporary per-role files and transfers only the variables required by each
VM. Service environment files are stored under `/etc/weather-forecast/` with
restricted permissions.

## Source layout

```text
fetcher/       Python provider client, worker, tests, requirements
history/       Go API, queue handling, storage, timers, tests
ui/            Static web page and browser JavaScript
migrations/    PostgreSQL schema migrations
vagrant/       Vagrantfile, provisioning scripts, service templates
docs/          Architecture documentation
```
