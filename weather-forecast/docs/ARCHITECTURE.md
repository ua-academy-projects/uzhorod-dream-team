# Weather Forecast Architecture

The application runs in Docker containers across four Ubuntu 24.04 Vagrant
VMs: six containers with RabbitMQ/Redis, or four in PostgreSQL mode.
A fifth Ubuntu VM, Bastion, provides SSH access and has no Docker
provisioning. systemd starts Docker Engine on the service VMs;
`unless-stopped` restart policies restart containers. Deployment uses Docker
CLI without Docker Compose.

## Components

| VM | Address | Ports | Responsibility |
| --- | --- | --- | --- |
| `db` | `192.168.56.11` | 5432; 5672 and 6379 in RabbitMQ/Redis mode | PostgreSQL; optional RabbitMQ and Redis |
| `fetcher` | `192.168.56.12` | 8001 inside container | Python Fetcher and queue worker |
| `history` | `192.168.56.13` | 8002 | Go API, timers, queue consumer, database writer |
| `ui` | `192.168.56.14` | 80 | Nginx and static HTML/CSS/JavaScript |
| `bastion` | external `192.168.122.10`; internal `192.168.56.10` | SSH | SSH jump host, internal DHCP/DNS, outbound gateway |

The UI VM port 80 is forwarded to port 8080 on the host. The browser
therefore uses `http://localhost:8080/` and sends relative `/api/` requests.
Other devices in the home network use `http://<host-LAN-IP>:8080/` while
the host is running and its firewall allows port 8080.

## Data flow

The browser sends requests only to Nginx. Nginx serves the static UI and
proxies `/api/` to History. History never calls Fetcher directly.

`WEATHER_BACKEND` selects the queue and preferences store at container startup.
The default `rabbitmq_redis` mode follows this path:

```text
browser -> Nginx -> History -> RabbitMQ weather.requests
                                      -> Fetcher -> Open-Meteo
                                      <- RabbitMQ weather.responses
                              History -> PostgreSQL
                              History -> browser
```

With `WEATHER_BACKEND=postgres`, messages travel through PostgreSQL instead:

```text
History -> PGMQ weather_requests -> Fetcher -> Open-Meteo
History <- PGMQ weather_responses <- Fetcher
History -> PostgreSQL weather_snapshots / temperature_history
```

History starts a collection when the page requests it, when the user presses
the collection button, and every 15 minutes. A job has a request ID and type.
History stores its state in PostgreSQL and publishes a durable message.
`POST /api/collect` returns `202 Accepted` with the request ID after RabbitMQ
confirms publication or PostgreSQL commits the job and request together.
The browser polls `GET /api/jobs/<request_id>` until the job is
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
- `weather_jobs` for queued, completed, and failed jobs, tagged with their backend;
- PGMQ `weather_requests` and `weather_responses` queues in the `pgmq` schema;
- `weather_preferences` with `hstore` key/value preferences and expiry times.

The `(city, weather_time)` key prevents duplicate current-weather rows. A
repeated collection updates the existing row and its `fetched_at` value.

RabbitMQ provides durable `weather.requests` and `weather.responses` queues.
Messages are persistent, publisher confirms are enabled, and consumers use
manual acknowledgements. History acknowledges a response only after the
database transaction succeeds. Fetcher acknowledges a request only after its
response is published successfully.

In PostgreSQL mode, PGMQ manages message delivery through `send`, `read`,
`set_vt`, and `delete`. Fetcher reads one request with a 30-second visibility
timeout, renewed every 10 seconds. The delivery count and visibility deadline
are checked under the message row lock before renewal or acknowledgement.
Publishing the response and acknowledging the request happen in one transaction.
History reads a response, saves the weather and job result, and acknowledges the
response in one transaction. Failed transactions leave messages available for
retry; job IDs prevent duplicate results. Idle workers poll once per second.

Redis stores only UI theme preferences in the default mode; PostgreSQL mode
uses `hstore` values in `weather_preferences` instead. The browser keeps a random
`weather_session` cookie; History uses it as the `session:<id>` Redis key.
In PostgreSQL it is the `session_id` key. The cookie and cache entry expire
after 30 days, with their lifetimes renewed
when preferences are read or saved. A missing entry returns the default light
theme. An expired PostgreSQL entry also returns the default; a background task
removes expired rows every five minutes. Reads renew TTL atomically without
overwriting concurrent preference updates. Redis failure does not remove
weather data from PostgreSQL.

Both application images support both modes. Selection and deployment commands
are documented in [BACKENDS.md](BACKENDS.md).

## Provisioning

`infra/vagrant/Vagrantfile` defines the five VMs, private addresses, resources,
rsync folders, filtered secret files, templates, and role-specific scripts.

The shared Vagrant provisioner prepares base packages and staging directories.
`infra/vagrant/provision/docker.sh` installs Docker Engine and enables its systemd
service on the four service VMs. Bastion has no Docker provisioning, application
rsync folder, or service credentials. Vagrant uses its own `vagrant` SSH account
and generated per-VM key to provision Bastion. `bastion.sh` configures the
forwarding-only `jump` account, internal DHCP/DNS, and the outbound firewall.
A readiness marker is written only after the gateway services are active;
service VM startup requires this marker and active gateway services.
No QEMU Guest Agent, custom base box, or experimental communicator is required.

`infra/vagrant/provision/common.sh` renders configuration, manages container replacement,
waits for database dependencies, and configures SSH. Role scripts in
`infra/vagrant/provision/` then:

- `db.sh` builds PostgreSQL 18 Alpine with PGMQ 1.13.0 and hstore and, in the default mode, runs RabbitMQ 4.3 and
  Redis 7.4 Alpine. It configures secrets and volumes, restores a dump into an
  empty database if available, and applies all migrations. PostgreSQL mode
  configures the Fetcher role and stops RabbitMQ/Redis without removing volumes;
- `fetcher.sh` builds the Python multi-stage image and starts the
  selected queue worker without publishing its internal HTTP port;
- `history.sh` builds the static Go binary in a multi-stage image
  and publishes port 8002 on the History VM private address;
- `ui.sh` builds the static Nginx image, mounts the rendered proxy
  configuration, and publishes port 80. Vagrant forwards host port 8080 through
  Bastion to the UI VM's internal address.

`WEATHER_BACKEND` comes from the ignored host deployment input. If omitted,
the default mode is preserved. `WEATHER_SKIP_BUILD=1` on the Vagrant command
reuses existing PostgreSQL and application images; by default provisioning builds them.

On an existing DB VM, provisioning first exports the native PostgreSQL 18
`weather_history` database. Application connections are disabled during this
migration. The native cluster and dump remain on disk for recovery, and the
native PostgreSQL, RabbitMQ, and Redis services are disabled. Existing native
RabbitMQ messages and Redis preferences are not imported into the new volumes.

Named volumes preserve PostgreSQL, RabbitMQ, and Redis state when containers
are replaced. Before `vagrant destroy db`, a Vagrant trigger runs
`operations/database/backup.sh` on the DB VM and saves a consistent PostgreSQL dump
to the host's ignored `var/deploy/weather_history.auto.dump`.
It boots a stopped DB VM without provisioning if needed. If backup or download
fails, destruction is aborted. A new DB VM automatically receives and restores
this dump before migrations. RabbitMQ messages and Redis preferences are not
backed up across VM destruction. PostgreSQL-mode queue and preferences tables
are included in the database dump. The dump represents the database at snapshot
time; later writes during destruction are outside that snapshot.

Explicit external import is still available with `WEATHER_IMPORT_DB=1` and
`weather_history.dump` plus `weather_history.count` in `var/deploy/`.
It refuses an existing database.

## Network and access

The project owns two libvirt networks:

- `weather-external`: NAT network `192.168.122.0/24`, host address
  `192.168.122.1`; only Bastion attaches here. The DHCP pool contains only
  `192.168.122.10`, giving its stock first NIC a stable address;
- `weather-internal`: a bridge without a host IP, libvirt DHCP,
  forwarding, or host IPv6. Bastion uses `192.168.56.10/24`; the four service
  VMs use `.11` through `.14` on their only NIC.

Bastion supplies internal DHCP/DNS and routes outbound traffic through NAT.
Fixed MAC reservations assign service addresses before SSH is available.
Vagrant uses these same fixed addresses for service SSH. The installed
vagrant-libvirt 0.12.2 otherwise queries libvirt DHCP even when `ssh.host` is
configured. A small driver override in Vagrantfile returns an explicitly
configured `ssh.host`, delegating normal discovery to the provider when none
is set. This also covers `vagrant ssh-config`, which does not run action
triggers. DHCP for the service VMs remains entirely on Bastion.
There is no direct host route into the internal network. The project no longer
attaches VMs to `default` or `vagrant0`. Vagrant creates both project networks
using provider options, without separate XML definitions or a setup script.
Bridge names are assigned by libvirt/Vagrant; inspect them with `net-dumpxml`
instead of assuming a particular `virbr` number.

Docker publishes PostgreSQL on the DB VM private address, and RabbitMQ/Redis
ports when those containers are running. PostgreSQL permits network access to
`weather_app` only from History and to `weather_fetcher` only from Fetcher,
using SCRAM password authentication. Loopback checks are also allowed inside
the DB container. The Fetcher role can consume PGMQ requests and publish responses; it cannot read weather records or preferences.
Containers use the
other VMs' private addresses, not Docker names across hosts. Fetcher does not
need an incoming published port; its worker connects outward to the selected
queue on DB.

During the first provisioning, Vagrant uses stock SSH port 22. It connects
directly to Bastion and reaches the service VMs through Bastion. Provisioning
then installs the public key from
`~/.ssh/weather_vm.pub`, disables password and root SSH login, and switches
the SSH service to `WEATHER_SSH_PORT`. New VM state automatically selects port
22 for bootstrap; subsequent commands use the configured port. The private
key never leaves the host. The SSH port is passed through configuration and is not stored in the
repository.

Service VMs use `sshd-services.conf`, which permits SSH login as `vagrant` only
from Bastion (`192.168.56.10`). There is no host-management-network exception.
Bastion uses `sshd_config` with `MaxSessions 0` for the ordinary `jump` account.
This account has no sudo and a nologin shell. It allows local TCP forwarding to
the four service IPs on port 22 (initial provisioning) or the configured SSH
port, and to UI port 80. Shells, remote commands, SFTP, agent forwarding, Unix
socket forwarding, remote forwarding, tunnels and TTYs are disabled for `jump`.

The administrative exception is `vagrant@192.168.122.1`: Vagrant can open SSH
sessions on Bastion from the host using its separate per-VM key. This permits
provisioning, file uploads and shutdown; `vagrant ssh bastion` also works.
Its local forwarding is restricted to UI port 80 for Vagrant's host port 8080
tunnel. The host public key for normal use is installed only for `jump`, not
added to the administrative account. This exception does not create a direct
network path to any service VM.
Client SSH aliases use `ProxyJump bastion`; Vagrant also connects to services
through Bastion for provisioning, rsync, and backups. The host port 8080 tunnel
connects directly to Bastion, which opens the connection to `192.168.56.14:80`.
The normal SSH route is:

```text
Host -> Bastion external (192.168.122.10) -> Bastion internal (192.168.56.10)
     -> db / fetcher / history / ui (192.168.56.11-14)
```

The client authenticates to both VMs using the private key on the host; agent
forwarding and a private key on Bastion are not required. Client aliases remain
in the host's existing `~/.ssh/config`: Bastion points to `192.168.122.10`, service
aliases point to their `.56.*` addresses, and services use `ProxyJump bastion`.
Bastion's alias must use `User jump`; the service aliases keep `User vagrant`.
They use the configured SSH port and `~/.ssh/weather_vm` as before. Vagrant's
proxy specifies Bastion's address and the host identity explicitly, so it does
not depend on those aliases. Its separate `infra/vagrant/.vagrant/known_hosts` file
uses accept-new checking; before a replacement VM is created, only that VM's
old entry is removed. Configure normal SSH to use the same file if you want
this host-key reset to apply to the aliases too.

The SSH allowlist is additional protection, not the network boundary. Service
VMs have no external NIC, the internal bridge has no host address, and Bastion
rejects new external-to-internal forwarded traffic. A direct SSH attempt from
the host must fail before authentication. Machine actions are sequential:
Bastion starts first and stops/destroys last, preserving the DB backup path.

### Transition and verification

Moving the source tree does not change VM interfaces or recreate domains.
Keep the existing `infra/vagrant/.vagrant/` state and host deployment inputs.
The ignored `Vagrantfile.previous` is a historical migration copy; it uses the
old layout and must not be used against the current environment.

Retire old `default`/`vagrant0` networks manually only after verifying that no
other live or persistent VM uses them, including powered-off VMs. Save their
XML first. An old `default` network on `192.168.122.0/24` must be retired
before creating `weather-external` on that subnet. If another
project needs it, resolve that conflict before migration. The preflight check
refuses overlapping network definitions; it never deletes them automatically.
The internal subnet must no longer have a host interface or route.
Do not run the old configuration against newly created project domains.

The existing host firewall drops incoming traffic by default. Its persistent
input chain needs DHCP for libvirt bridges and DNS from Bastion, before the
final drop. These rules can replace the old broad `iifname "virbr0" accept`
when that rule is no longer needed by another project:

```nft
iifname "virbr*" udp sport 68 udp dport 67 accept
iifname "virbr*" ip saddr 192.168.122.10 udp dport 53 accept
iifname "virbr*" ip saddr 192.168.122.10 tcp dport 53 accept
```

Keep loopback, established/related, and the home-LAN port 8080 rule. Do not flush
the host's live ruleset after libvirt/Docker have installed their own rules.
Host firewall and `~/.ssh/config` are not modified by project provisioning.

After the host preparation, ordinary `vagrant up` creates the networks and
starts Bastion before the services. After updating SSH aliases, check:

```bash
virsh -c qemu:///system net-dumpxml weather-external
virsh -c qemu:///system net-dumpxml weather-internal
virsh -c qemu:///system domiflist vagrant_bastion
vagrant ssh bastion -c 'ip -br -4 addr; ip -4 route'
vagrant ssh db -c 'ip -br -4 addr; ip -4 route'
ssh -v db hostname
timeout 8s ssh -o ProxyJump=none -o ConnectTimeout=5 db hostname
ssh bastion hostname
ssh -T bastion
curl -f http://127.0.0.1:8080/api/latest
```

Expect two NICs on Bastion, one on DB, DB's default route via `.56.10`, and a
working SSH proxy. The default libvirt domain prefix is `vagrant_`; use the
actual name from `virsh list --all` if yours differs. Direct service SSH must
fail before authentication; Bastion SSH commands and shell sessions through
the ordinary `jump` alias must be refused after authentication. The separate
Vagrant administrative connection is expected to work. The external network has only Bastion attached;
`weather-internal` XML has no `<ip>` or `<forward>` element. Also check
`ssh -R` to Bastion is refused, and forwarding to an unlisted destination is
refused when a client attempts to use it. Check all four service aliases,
Fetcher's outbound DNS/HTTPS, log collection, `vagrant provision db`,
`vagrant provision bastion`, and halt/up behavior separately. Vagrant must
recreate the port 8080 tunnel after provisioning switches SSH ports. Bastion
shutdown uses Vagrant's administrative SSH connection and the provider's normal
shutdown handling. Halting or destroying only Bastion while dependent service
VMs remain running/defined is refused. A full destroy/up backup/restore check is still a
deployment verification, not something local syntax validation can prove.

Secrets stay in the local `var/deploy/secrets.env`. Vagrant creates
temporary per-role files and transfers only the variables required by each
VM. Service environment files are stored under `/etc/weather-forecast/` with
restricted permissions.
In PostgreSQL mode, DB receives the application and Fetcher database passwords,
History receives only its application database password, and Fetcher receives
only its separate database password. UI and Bastion receive no service secrets.

## Source layout

```text
services/
  fetcher/                Python Fetcher package and Docker build context
    app.py                HTTP app
    config.py             Environment configuration
    provider.py           Open-Meteo client
    worker.py             Shared job execution and RabbitMQ worker
    postgres_worker.py    PGMQ worker
    tests/                Python tests
  history/                Go main package and Docker build context
    main.go               Startup and schedulers
    server.go             HTTP API
    broker.go             RabbitMQ messaging
    store.go              PostgreSQL weather storage
    postgres_queue.go     PGMQ consumer
    *_test.go             Tests beside the implementation
  ui/public/              Static HTML and CSS/JavaScript assets
infra/
  postgres/               PostgreSQL Dockerfile and migrations/
  vagrant/                Vagrantfile, provision/, templates/
operations/
  database/               PostgreSQL backup script executed on the DB VM
  logs/                   Host collector and cron template
docs/                     Project documentation
var/                      Ignored local deployment inputs and log archives
```

Docker build contexts are `services/fetcher`, `services/history`, `services/ui`,
and `infra/postgres`. Provisioning maps these host paths to the existing VM
staging directories. SQL migrations remain a separate rsync folder on DB;
they are not included in its image build context. Commands using Vagrant run
from `infra/vagrant/`. VM state and Vagrant's generated keys are kept in that
directory's ignored `.vagrant/` folder.

From the project root, run Python tests with
`.venv/bin/python -m pytest services/fetcher/tests`. For Go, change to
`services/history/`, then run `go test ./...` and
`go build -o bin/history .`. Local startup uses
`python -m fetcher` from `services/` and `go run .` from
`services/history/`, with the chosen backend environment configured. History's
default local UI directory is `../ui/public`; deployed History containers keep
`HISTORY_SERVE_UI=false` and use the separate Nginx VM.

## Logs

All service containers use Docker's `local` log driver with `max-size=10m` and
`max-file=3`. Docker rotates container stdout/stderr logs on each VM.
`docker logs` reads them. Container replacement removes those local logs.

`operations/logs/collect.sh` collects logs onto the host from `db`,
`fetcher`, `history`, and `ui`. Bastion is not currently included. The script
uses the host's SSH aliases, so service VM connections follow `ProxyJump`
when configured. `BatchMode=yes` and `sudo -n` require access without
interactive password or passphrase prompts.

The collector retrieves two sources:

- the system journal through `journalctl`, including service and kernel
  messages recorded by journald;
- container stdout/stderr through `docker logs`, including retained logs from
  stopped containers. Missing optional RabbitMQ/Redis containers are skipped;
  missing required containers or Docker access failures are reported.

The Docker `local` driver stores container output separately from journald.
Collecting the system journal therefore does not retrieve the same Docker
log stream a second time. Files written only to other paths, such as
application-specific files under `/var/log`, are not collected automatically.

The first collection requests up to 14 days of available logs. Later runs use
journal cursors and Docker timestamps saved under `var/logs/current/.state/`. Checkpoints
advance after a successful transfer and local save; an unavailable VM is
skipped without advancing its checkpoints. A lock prevents overlapping runs.
Logs already removed by local rotation cannot be recovered by the collector.

Files are grouped under `var/logs/current/<vm>/system/` and
`var/logs/current/<vm>/containers/<container>/`. Directories are created with mode `700`
and files with mode `600`; logs and checkpoint files are ignored by Git.

`operations/logs/collector.cron` is a template for the host user's crontab.
It schedules collection every 15 minutes using absolute paths and writes
collector diagnostics to daily `var/logs/current/collector-<UTC-date>.log` files. Keeping
the template in the repository does not install or activate the schedule.

Each run compresses `.log` files older than one day with gzip and removes
`.log.gz` files older than 14 days. Age is measured from the file's modification
time on the host, not the timestamp of individual log messages; gzip preserves
that modification time. This also applies to collector diagnostic logs.

After destroying a VM environment, manually move `var/logs/current/` to
`var/logs/archive/logs-<timestamp>.old/` before collecting from replacement VMs.
The collector does not detect VM replacement or rename directories automatically.
New runs create a fresh `var/logs/current/` tree and checkpoints; compression
and retention also cover `var/logs/archive/logs-*.old/` archives.
