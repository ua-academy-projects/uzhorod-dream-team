# weather-history

A small weather-history service built as a DevOps learning project. Every 5 minutes it gets
the current temperature in Lviv from [Open-Meteo](https://open-meteo.com/), stores it in
PostgreSQL and shows the history on a web page.

The application itself is simple on purpose. The focus is on the infrastructure around it:
two services that talk only through a message queue, four Vagrant VMs built entirely by
provisioning scripts, Docker containers, an isolated internal network with a bastion host,
and per-port firewall rules.

## Features

- Two services in two languages: **History** (Go) and **Fetcher** (Python).
- The services never call each other. They exchange JSON messages through RabbitMQ queues,
  or through PostgreSQL queues (pgmq) in the second app mode.
- A message is acknowledged only after it is processed, so a crash does not lose data.
- No duplicates: `UNIQUE (city, observed_at)` in the database.
- If Open-Meteo fails, the error is logged and nothing is stored. The service never makes up
  weather data.
- Web UI with light/dark theme and Ukrainian/English language. The choice is kept per browser
  in Redis (or PostgreSQL `hstore`) for 30 days.
- Everything is reproducible: `vagrant up` builds all VMs from scratch, with no manual steps
  inside the VMs.
- A health check script tests every service, connection, firewall rule and the whole data
  path end to end.

## Architecture

```
                       weather.requests
History (Go) ─────────► RabbitMQ ─────────► Fetcher (Python) ──HTTPS──► Open-Meteo API
     ▲                                             │
     │                 weather.responses           │
     └──────────────── RabbitMQ ◄──────────────────┘
     │
     ├──► PostgreSQL   weather history
     └──► Redis        UI settings (theme, language)
```

| Component | Path | What it does |
|---|---|---|
| History | `history/` | Go service. At start and every 5 minutes it puts a request into `weather.requests`. It reads `weather.responses` and saves each record to PostgreSQL. It serves the UI, `GET /api/history` (latest 100 records, newest first) and `GET`/`PUT /api/settings`. |
| Fetcher | `fetcher/` | Python worker without an HTTP server. It takes a request, calls Open-Meteo with a timeout and publishes the response. |
| RabbitMQ | `provision/broker.sh` | Quorum queues `weather.requests` and `weather.responses`. |
| PostgreSQL | `db/schema.sql` | Table `weather_records`. Extensions pgmq, pg_cron and hstore for the second mode. |
| Redis | `provision/cache.sh` | UI settings, linked to a browser cookie. |
| UI | `ui/` | Plain HTML/CSS/JavaScript: latest temperature and history in Kyiv time. |

### Message flow

1. History publishes `{"request_id": "...", "requested_at": "2026-10-11T18:00:09Z"}` to
   `weather.requests`.
2. Fetcher calls Open-Meteo and publishes the result to `weather.responses`. Only after that
   does it ack the request.
3. History saves the record to PostgreSQL and only then acks the response.

```json
{"request_id": "S5HL2F...", "ok": true,
 "record": {"city": "Lviv", "temperature_c": 11.5,
            "observed_at": "2026-10-11T18:00:00Z", "fetched_at": "2026-10-11T18:00:10Z"}}
```

`observed_at` is the time of the measurement from Open-Meteo. `fetched_at` is the time of our
request. All times are stored in UTC and sent between the services in RFC 3339 with `Z`.

| Situation | Behaviour |
|---|---|
| Fetcher is down | Requests wait in the queue for up to 5 minutes (`x-message-ttl`). |
| History is down | Responses wait in `weather.responses` until History starts again. |
| Database is temporarily down | History waits 5 seconds and returns the response to the queue. |
| A message keeps failing | It is dropped after 5 deliveries (`x-delivery-limit`). |
| Broken message | It is logged and rejected without a retry. |
| Same response delivered twice | `ON CONFLICT DO NOTHING`, so no duplicate is stored. |

## Infrastructure

Four VirtualBox VMs (`bento/ubuntu-24.04`) managed by Vagrant from WSL:

| VM | Role | RAM | Internal IP | Runs |
|---|---|---|---|---|
| `bastion-vm` | The only SSH entry point | 512 MB | 10.10.10.13 (+ 192.168.56.13) | `sshd`, `ufw` |
| `weather-vm` | Data and messaging | 1536 MB | 10.10.10.10 | PostgreSQL 16 (systemd), containers `weather-rabbitmq`, `weather-redis` |
| `fetcher-vm` | Fetcher | 512 MB | 10.10.10.11 | container `weather-fetcher` |
| `history-vm` | History and UI | 1024 MB | 10.10.10.12 | container `weather-history` |

### Networks

```
Windows / WSL
     │  host-only 192.168.56.0/24
     ▼
bastion-vm ── SSH ProxyJump ──► internal network "weather-internal" 10.10.10.0/24
                                weather-vm · fetcher-vm · history-vm
```

- **Internal Network** (`weather-internal`): only the VMs are connected. Windows and WSL have no
  route to `10.10.10.x`. All service traffic goes here.
- **Host-only**: only the bastion is on it, so it is the only VM reachable from the host.
- **NAT**: internet access for each VM, plus the forwarded ports used by Vagrant and the UI
  (`127.0.0.1:8081` → `history-vm:8080`).

### Security

- **Firewall on `weather-vm`** (`provision/db-firewall.sh`). Every port is open only to the
  VM that needs it:

  | Port | Service | Allowed from |
  |---|---|---|
  | 5432 | PostgreSQL | `history-vm`; `fetcher-vm` only in `postgres` mode, over TLS |
  | 5672 | RabbitMQ | `fetcher-vm`, `history-vm` |
  | 6379 | Redis | `history-vm` |

- **No `docker run --publish` on `weather-vm`.** A published port would bypass `ufw`, so
  RabbitMQ and Redis use `--network host` and stay behind the firewall.
- **SSH**: login with a key only, no passwords. Each VM gets its own host keys. On the internal
  VMs the personal key is accepted only from the bastion (`from="10.10.10.13"`), and `sshd`
  accepts users only from the bastion and Vagrant.
- **Secrets** live only in `.env` (git-ignored). In the VMs they are written to files that only
  root and the service user can read. They never end up in an image.
- **Containers** run as non-root users. The History image is a two-stage build on
  `distroless/static` (about 24 MB, no shell).

### Two app modes

`app_mode` in `weather-vm.yml` selects how the services talk and where the UI settings are kept:

| | `rabbitmq` (default) | `postgres` |
|---|---|---|
| Queues | RabbitMQ | pgmq: `weather_requests`, `weather_responses` |
| UI settings | Redis with a 30-day TTL | `user_settings` table (`hstore`), cleaned by a pg_cron job |
| Fetcher → PostgreSQL | blocked (role is `NOLOGIN`, port closed) | allowed from `fetcher-vm` only, TLS |

Switch modes only with the script. It waits until the old queues are empty, so no message is lost:

```bash
./scripts/switch-mode.sh postgres
./scripts/switch-mode.sh rabbitmq
```

## Repository layout

```
├── Vagrantfile            # 4 VMs, networks, files to copy, provisioning steps
├── weather-vm.yml         # database names, app_mode, queue poll interval
├── .env.example           # template for the secrets
├── provision/             # shell scripts that run inside the VMs
├── history/               # Go service + Dockerfile
├── fetcher/               # Python service + Dockerfile
├── ui/                    # web page
├── db/schema.sql          # database schema
├── scripts/               # switch-mode.sh, collect-logs.sh
├── healthcheck.sh         # checks all VMs, connections and the data path
├── ssh-proxy.ps1          # SSH bridge for Vagrant in WSL (see below)
└── ssh-trust.sh           # adds the VM host keys to ~/.ssh/known_hosts
```

## Getting started

### Requirements

- Windows with VirtualBox, and about 4 GB of free RAM for the four VMs.
- WSL (Ubuntu) with Vagrant of the **same version** as on Windows.
- Internet access for packages, Docker images and Open-Meteo.

### 1. Let Vagrant in WSL use Windows VirtualBox

Add to `~/.bashrc`, then open a new terminal:

```bash
export VAGRANT_WSL_ENABLE_WINDOWS_ACCESS="1"
export VAGRANT_WSL_WINDOWS_ACCESS_USER_HOME_PATH="/mnt/c/Users/<your-windows-user>"
```

In NAT mode WSL cannot reach the Windows `127.0.0.1`, where VirtualBox forwards the SSH ports
of the VMs. For this reason the Vagrantfile sends `vagrant ssh` through `ssh-proxy.ps1`, which
runs on Windows. No WSL or Hyper-V settings are changed.

### 2. Create `.env`

```bash
cp .env.example .env
chmod 600 .env
for name in WEATHER_DB_PASSWORD RABBITMQ_PASSWORD REDIS_PASSWORD FETCHER_DB_PASSWORD; do
  sed -i "s/^$name=.*/$name=$(openssl rand -hex 16)/" .env
done
```

Every password must be at least 16 letters or digits. If one is missing or too short, the
Vagrantfile stops with a clear error.

### 3. (Optional) SSH key for access through the bastion

```bash
ssh-keygen -t ed25519 -f ~/.ssh/weather_history_ed25519 -C "weather-history"
```

Do this before `vagrant up`, or run `vagrant provision --provision-with ssh-key` afterwards.

### 4. Start

```bash
vagrant validate
vagrant up
```

The first run takes a while. Building the Go image in `history-vm` alone can take about
10 minutes. When it finishes, open <http://127.0.0.1:8081/> in a Windows browser.

### 5. Check

```bash
./healthcheck.sh
```

It prints one `OK`/`FAIL` line per check and exits with code `1` if any check fails. Example
in `rabbitmq` mode (shortened):

```
Mode: rabbitmq
weather-vm: PostgreSQL: OK
weather-vm: RabbitMQ container: OK
history-vm -> PostgreSQL :5432: OK
fetcher-vm -> Redis :6379 blocked: OK
Fetcher reads weather.requests (1 consumer): OK
Settings saved and read back (Redis): OK
Fresh record (< 30 min): OK
```

`Fresh record` tests the whole path: History → queue → Fetcher → Open-Meteo → queue →
History → PostgreSQL → API. It can fail for a few minutes after the first start.

## SSH through the bastion

After `./ssh-trust.sh` has added the VM host keys, add this to `~/.ssh/config`:

```
Host bastion
    HostName 192.168.56.13
    HostKeyAlias bastion-vm
Host weather
    HostName 10.10.10.10
    HostKeyAlias weather-vm
Host fetcher
    HostName 10.10.10.11
    HostKeyAlias fetcher-vm
Host history
    HostName 10.10.10.12
    HostKeyAlias history-vm
Host weather fetcher history
    ProxyJump bastion
Host bastion weather fetcher history
    User vagrant
    IdentityFile ~/.ssh/weather_history_ed25519
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PasswordAuthentication no
    StrictHostKeyChecking yes
    ForwardAgent no
```

Then `ssh weather`, `ssh fetcher` and `ssh history` go through the bastion. The bastion only
forwards the encrypted connection, and the private key never leaves WSL.

## Everyday commands

```bash
# copy new code into the VMs and re-run provisioning
vagrant provision history-vm
vagrant provision fetcher-vm

# run only some steps (each step is named after its script)
vagrant provision weather-vm --provision-with docker,broker,cache,db-firewall

# rebuild one image after a code change
vagrant provision history-vm --provision-with file,history-image,history

# logs
ssh history 'sudo docker logs --tail 20 weather-history'
./scripts/collect-logs.sh        # last 24 h of all containers into logs/ (git-ignored)

# queues
vagrant ssh weather-vm -c "sudo docker exec weather-rabbitmq rabbitmqctl --silent list_queues -p weather name messages consumers"

# stop / start
vagrant halt
vagrant up
```

Provisioning can be run again safely. It does not delete the database, queued messages or
saved settings.

## Tests

The tests need no servers: RabbitMQ, Redis and Open-Meteo are replaced with fakes.

```bash
python3 -m venv fetcher/.venv
fetcher/.venv/bin/pip install -r fetcher/requirements.txt
(cd fetcher && .venv/bin/python -m unittest -v)
(cd history && go test ./...)
```

| Tests | What they cover |
|---|---|
| `fetcher/test_weather.py` | parsing the Open-Meteo response, UTC times |
| `fetcher/test_messages.py` | parsing requests; success and error responses, with no invented data |
| `history/main_test.go` | `/api/history`, UI files, `Cache-Control` |
| `history/messages_test.go` | request format; ack, reject or retry for each response |
| `history/settings_test.go` | cookie sessions, saving theme and language, invalid input, `503` without Redis |

## Optional: open the UI from a phone

Set `UI_LAN_IP` in `.env` to the laptop's Wi-Fi IPv4 address and run
`vagrant reload history-vm`. Port 8081 is then also forwarded on that address. You also need a
Windows Firewall rule that allows TCP 8081 only from the home subnet to `VBoxHeadless.exe`
(PowerShell as Administrator; replace the two addresses with your own):

```powershell
New-NetFirewallRule -DisplayName "weather-history UI 8081 (LAN)" -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8081 -LocalAddress <UI_LAN_IP> -RemoteAddress <home-subnet>/24 `
  -InterfaceAlias "Wi-Fi" -Program "C:\Program Files\Oracle\VirtualBox\VBoxHeadless.exe" -Profile Private,Public
```

If Windows asks whether to allow "VirtualBox Headless Frontend", do not allow it: that opens
every VirtualBox port to the network. PostgreSQL, RabbitMQ and Redis are never exposed.

## Tech stack

Go 1.26 (`pgx`, `amqp091-go`, `go-redis`, `godotenv`) · Python 3.12 (`httpx`, `pika`,
`python-dotenv`, `psycopg`) · PostgreSQL 16 with pgmq, pg_cron, hstore · RabbitMQ 3.12 ·
Redis 7.0 · Docker · Vagrant + VirtualBox · ufw · WSL
