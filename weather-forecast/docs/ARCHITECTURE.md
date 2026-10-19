# Weather Forecast Architecture

The application runs in six Docker containers across four Ubuntu 24.04
Vagrant VMs. A fifth Ubuntu VM, Bastion, provides SSH access and has no Docker
provisioning. systemd starts Docker Engine on the service VMs;
`unless-stopped` restart policies restart containers. Deployment uses Docker
CLI without Docker Compose.

## Components

| VM | Address | Ports | Responsibility |
| --- | --- | --- | --- |
| `db` | `192.168.56.11` | 5432, 5672, 6379 | PostgreSQL, RabbitMQ, Redis |
| `fetcher` | `192.168.56.12` | 8001 inside container | Python Fetcher and RabbitMQ worker |
| `history` | `192.168.56.13` | 8002 | Go API, timers, queue consumer, database writer |
| `ui` | `192.168.56.14` | 80 | Nginx and static HTML/CSS/JavaScript |
| `bastion` | `192.168.56.10` | SSH | SSH jump host; client ProxyJump configuration is separate |

The UI VM port 80 is forwarded to port 8080 on the host. The browser
therefore uses `http://localhost:8080/` and sends relative `/api/` requests.
Other devices in the home network use `http://<host-LAN-IP>:8080/` while
the host is running and its firewall allows port 8080.

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
History stores its state in PostgreSQL and publishes a durable message.
`POST /api/collect` returns `202 Accepted` with the request ID after publication
is confirmed. The browser polls `GET /api/jobs/<request_id>` until the job is
completed or failed, then loads the saved weather. Fetcher responses are
processed asynchronously and validated before they are stored.

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
The cookie and Redis entry expire after 30 days, with their lifetimes renewed
when preferences are read or saved. A missing entry returns the default light
theme. Redis failure does not remove weather data from PostgreSQL.

## Provisioning

`vagrant/Vagrantfile` defines the five VMs, private addresses, resources,
rsync folders, filtered secret files, templates, and role-specific scripts.

The shared Vagrant provisioner prepares base packages and staging directories.
`vagrant/provision/docker.sh` installs Docker Engine and enables its systemd
service on the four service VMs. Bastion has no Docker provisioning, application
rsync folder, or service credentials; `bastion.sh` only configures SSH.
`vagrant/provision/common.sh` renders configuration, manages container replacement,
waits for database dependencies, and configures SSH. Role scripts in
`vagrant/provision/` then:

- `db.sh` runs official PostgreSQL 18, RabbitMQ 4.3, and Redis 7.4 Alpine
  images, configures runtime secrets and persistent volumes, restores a dump
  into an empty database if available, and applies all SQL migrations;
- `fetcher.sh` builds the Python multi-stage image and starts the
  RabbitMQ worker without publishing its internal HTTP port;
- `history.sh` builds the static Go binary in a multi-stage image
  and publishes port 8002 on the History VM private address;
- `ui.sh` builds the static Nginx image, mounts the rendered proxy
  configuration, and publishes port 80 for Vagrant's host port 8080 forward.

On an existing DB VM, provisioning first exports the native PostgreSQL 18
`weather_history` database. Application connections are disabled during this
migration. The native cluster and dump remain on disk for recovery, and the
native PostgreSQL, RabbitMQ, and Redis services are disabled. Existing native
RabbitMQ messages and Redis preferences are not imported into the new volumes.

Named volumes preserve PostgreSQL, RabbitMQ, and Redis state when containers
are replaced. Before `vagrant destroy db`, a Vagrant trigger runs
`vagrant/scripts/backup-db.sh` on the DB VM and saves a consistent PostgreSQL dump
to the host's ignored `weather-deploy-input/weather_history.auto.dump`.
It boots a stopped DB VM without provisioning if needed. If backup or download
fails, destruction is aborted. A new DB VM automatically receives and restores
this dump before migrations. RabbitMQ messages and Redis preferences are not
backed up across VM destruction. The dump represents the database at snapshot
time; later writes during destruction are outside that snapshot.

Explicit external import is still available with `WEATHER_IMPORT_DB=1` and
`weather_history.dump` plus `weather_history.count` in `weather-deploy-input/`.
It refuses an existing database.

## Network and access

All five VMs have addresses on the private `192.168.56.0/24` network.
Vagrant/libvirt also attaches a management interface to the existing `default`
network, configured as `192.168.122.0/24`. Management addresses are assigned
dynamically; the host management address used by the SSH allowlist is
`192.168.122.1`.

Docker publishes PostgreSQL, RabbitMQ, and Redis ports on the DB VM private
address. PostgreSQL permits network access to `weather_app` only from the
History VM and requires SCRAM password authentication. Containers use the
other VMs' private addresses, not Docker names across hosts. Fetcher does not
need an incoming published port; its worker connects outward to RabbitMQ.

During the first provisioning, Vagrant uses the stock SSH connection to
bootstrap the VM. Provisioning then installs the public key from
`~/.ssh/weather_vm.pub`, disables password and root SSH login, and switches
the SSH service to `WEATHER_SSH_PORT`. New VM state automatically selects port
22 for bootstrap; subsequent commands use the configured port. The private
key never leaves the host. The SSH port is passed through configuration and is not stored in the
repository.

Service VMs use `sshd-services.conf`, which permits SSH login as `vagrant` only
from Bastion (`192.168.56.10`) or the host management address
(`192.168.122.1`). Bastion uses the base `sshd_config` template. Client SSH
aliases use `ProxyJump bastion`; Vagrant retains direct management access for
provisioning, rsync, backups, and the UI SSH port-forwarding tunnel.
The normal SSH route is:

```text
Host SSH client -> Bastion (192.168.56.10) -> db / fetcher / history / ui
```

The client authenticates to both VMs using the private key on the host; agent
forwarding and a private key on Bastion are not required. The SSH aliases are
configured separately in the host's `~/.ssh/config`.

This is an SSH login restriction, not a firewall rule. The management exception
is based on the source address and also permits manual connections from that
address. If these addresses change, update the service SSH template.

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
vagrant/       Vagrantfile and configuration templates
vagrant/provision/  Role-specific provisioning scripts and shared helpers
vagrant/scripts/    VM maintenance scripts, including PostgreSQL backup
scripts/       Host-side VM log collection
cron/          Cron template for the host
docs/          Architecture documentation
```

## Logs

All six containers use Docker's `local` log driver with `max-size=10m` and
`max-file=3`. Docker rotates container stdout/stderr logs on each VM.
`docker logs` reads them. Container replacement removes those local logs.

`scripts/collect-vm-logs.sh` collects logs onto the host from `db`,
`fetcher`, `history`, and `ui`. Bastion is not currently included. The script
uses the host's SSH aliases, so service VM connections follow `ProxyJump`
when configured. `BatchMode=yes` and `sudo -n` require access without
interactive password or passphrase prompts.

The collector retrieves two sources:

- the system journal through `journalctl`, including service and kernel
  messages recorded by journald;
- stdout/stderr from each of the six containers through `docker logs`.

The Docker `local` driver stores container output separately from journald.
Collecting the system journal therefore does not retrieve the same Docker
log stream a second time. Files written only to other paths, such as
application-specific files under `/var/log`, are not collected automatically.

The first collection requests up to 14 days of available logs. Later runs use
journal cursors and Docker timestamps saved under `logs/.state/`. Checkpoints
advance after a successful transfer and local save; an unavailable VM is
skipped without advancing its checkpoints. A lock prevents overlapping runs.
Logs already removed by local rotation cannot be recovered by the collector.

Files are grouped under `logs/<vm>/system/` and
`logs/<vm>/containers/<container>/`. Directories are created with mode `700`
and files with mode `600`; logs and checkpoint files are ignored by Git.

`cron/weather-log-collector.cron` is a template for the host user's crontab.
It schedules collection every 15 minutes using absolute paths and writes
collector diagnostics to daily `logs/collector-<UTC-date>.log` files. Keeping
the template in the repository does not install or activate the schedule.

Each run compresses `.log` files older than one day with gzip and removes
`.log.gz` files older than 14 days. Age is measured from the file's modification
time on the host, not the timestamp of individual log messages; gzip preserves
that modification time. This also applies to collector diagnostic logs.

After destroying a VM environment, manually rename `logs/` to
`logs-<timestamp>.old/` before collecting from replacement VMs. The collector
does not detect VM replacement or rename directories automatically. New runs
create a fresh `logs/` tree and checkpoints; compression and retention also
cover `logs-*.old/` archives.
