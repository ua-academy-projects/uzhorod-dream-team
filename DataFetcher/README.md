# DataFetcher

This directory contains the price collection applications and web UI, PostgreSQL initialization SQL, and the Docker Compose configuration.

## Services

| Service | Implementation | Role |
| --- | --- | --- |
| `fetcher` | Go | Polls price sources, serves the latest values, and processes collection tasks |
| `history` | Go | Periodically requests Fetcher, stores records, and provides an HTTP API |
| `ui` | FastAPI | Displays data and charts and stores user preferences |
| `postgres` | PostgreSQL 16 | Stores history, tasks, and preferences; provides PGMQ and HSTORE as needed |
| `rabbitmq`, `redis` | RabbitMQ, Redis | Request broker and preference cache for `hybrid` mode |

## Backend modes

`APP_BACKEND` must be the same for all three applications.

| Mode | Queue between History and Fetcher | UI preferences | Required services |
| --- | --- | --- | --- |
| `hybrid` | RabbitMQ; a PostgreSQL queue is available as a Fetcher fallback | PostgreSQL is the source of truth; Redis is the cache | PostgreSQL, RabbitMQ, Redis |
| `postgres` | PGMQ in PostgreSQL | HSTORE in PostgreSQL | PostgreSQL |

In `postgres` mode, the applications do not connect to RabbitMQ or Redis. See the [backend modes guide](../docs/BROKER_MODE.md) for details.

## Docker Compose

You need Docker Compose. Create a local configuration from the template and set your own passwords:

```powershell
Copy-Item .env.example .env
```

Set `APP_BACKEND=hybrid` or `APP_BACKEND=postgres`, validate the configuration, and start the services:

```sh
docker compose config
docker compose up --build -d
docker compose ps
docker compose logs -f ui history fetcher postgres
```

UI: [http://localhost:8000](http://localhost:8000). The History API is published on `http://localhost:8002`, and Fetcher on `http://localhost:8001`.

Stop the services while keeping volumes with `docker compose down`. The command `docker compose down -v` also deletes PostgreSQL, Redis, and RabbitMQ data.

The PostgreSQL image `ghcr.io/pgmq/pg16-pgmq:v1.10.0` includes the PGMQ files. `CREATE EXTENSION pgmq` registers the extension in a database; it does not install the extension files. The image also provides HSTORE.

## Vagrant

From the repository root, copy the Vagrant configuration template:

```powershell
Copy-Item DataFetcher\env_vagrant_example DataFetcher\.env
```

Set your passwords and configure the network bridge in the root `Vagrantfile`, then run `vagrant up`. The deployment creates five VMs; PostgreSQL, RabbitMQ, and Redis run together on the `postgres` VM. After changing `.env`, reprovision the VMs whose containers need the updated values:

```sh
vagrant provision postgres
vagrant provision fetcher
vagrant provision history
vagrant provision ui
```

See the [Vagrant guide](../docs/VAGRANT_BROKER_MODE.md) for detailed instructions.

## Configuration

Templates: [`.env.example`](.env.example) for Compose and [`env_vagrant_example`](env_vagrant_example) for Vagrant. Main variables:

- `APP_BACKEND` — `hybrid` or `postgres`.
- `SOURCES` — comma-separated `name=URL` pairs.
- `HISTORY_INTERVAL_SECONDS` — collection interval in seconds (10 seconds in the templates).
- `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` — History/UI connection settings.
- `FETCHER_POSTGRES_HOST`, `FETCHER_POSTGRES_PORT`, `FETCHER_POSTGRES_DB`, `FETCHER_POSTGRES_USER`, `FETCHER_POSTGRES_PASSWORD` — Fetcher's queue credentials.
- `RABBITMQ_URL`, `REDIS_URL` — used in `hybrid` mode.
- `HISTORY_SERVICE_URL` — History address used by UI; `COOKIE_SECURE` controls secure cookies for HTTPS.

Do not commit `.env`; it contains passwords.

## Health checks and database inspection

```sh
docker compose ps
docker compose logs --tail 100 postgres history fetcher
```

For extension installs, check `SELECT extname FROM pg_extension WHERE extname IN ('pgmq', 'hstore');`. SQL-only PGMQ is checked with `SELECT to_regprocedure('pgmq.send(text,jsonb)');`. Check queues with `SELECT * FROM pgmq.list_queues();`. In `postgres` mode, completed tasks are in `fetcher_tasks`, active messages are in `pgmq.q_fetcher_tasks`, and price records are in `history`.

## Development

Run the Go service tests:

```sh
cd fetcher && go test ./...
cd ../history && go test ./...
```

Run UI tests (install packages from `ui/requirements-dev.txt` first):

```sh
cd ui
APP_BACKEND=postgres python -m pytest -q
```


## Поточний режим: HTTPS на статичній IP без домену

У `config.json` для UI встановлено `startup.ip_https: true`.
Cloudflare Tunnel у цьому режимі не запускається, токен не потрібний.
Terraform резервує статичну публічну IP та дозволяє TCP 80/443 лише для
VM із тегом `ui-service`. UI:8000 залишається прив'язаним до localhost.

Startup script на UI VM:

1. Запускає UI і Nginx з HTTP endpoint для ACME-перевірки.
2. Встановлює Certbot >= 5.4 у Python venv.
3. Отримує довірений IP-сертифікат Let's Encrypt через HTTP-01
   (`--ip-address`, профіль `shortlived`).
4. Вмикає Nginx HTTPS на 443 і редирект HTTP → HTTPS на фактичну IP VM.
   ACME challenge та локальна healthcheck-адреса залишаються доступними по HTTP.
5. Встановлює systemd timer `datamonitor-ip-https.timer`: перевірка сертифіката
   кожні шість годин, повторна спроба також у разі невдалої першої видачі.
   Після перевірки/поновлення Nginx перечитує сертифікат.

Сертифікати та ключі лежать у `/etc/letsencrypt` на boot-диску UI VM.
Вони переживають перезапуск VM; при видаленні boot-диска буде потрібна нова
видача. Для перевірки Let's Encrypt має досягати публічного порту 80;
поки VM зупинена, поновлення не працює. IP-сертифікат діє близько шести днів.
Certbot реєструє ACME-акаунт без email; значення email у конфігу не потрібне.

Перевірка після розгортання:

```bash
terraform -chdir=gcp-terra output -raw ui_public_ip
```

На UI VM:

```bash
systemctl status datamonitor-ip-https.timer
journalctl -u datamonitor-ip-https.service --no-pager -n 50
docker logs datamonitor-nginx --tail 50
/opt/datamonitor-certbot/bin/certbot certificates
```

Відкрийте `http://UI_IP/`: очікується перенаправлення на `https://UI_IP/`.
Початкова видача сертифіката виконується у startup script;
`terraform apply` сам по собі не підтверджує, що вона вже завершилась.

## Cloud SQL over private IP

History and Fetcher use the Cloud SQL Go Connector when
`INSTANCE_CONNECTION_NAME=PROJECT:REGION:INSTANCE` is set. Leave it empty for
local/Vagrant PostgreSQL. Compose passes this variable to both applications.
For GCP deployments, `config.json` selects `database.provider` and
`compute.application.app_backend`; Terraform supplies routing settings in startup
metadata, overriding the environment secret. Credentials remain in the secret.
See [bootstrap configuration](../gcp-terra/bootstrap/README.md#вибір-бази-та-бекенду).

The connector always uses private IP and supplies authenticated TLS. The VM must
have a network route to Cloud SQL and a service account with `roles/cloudsql.client`;
Cloud SQL Admin API must be enabled. On Compute Engine credentials come from the
attached service account, so do not copy service account keys into containers.

Set `POSTGRES_DB=history` and `FETCHER_POSTGRES_DB=history`, the Cloud SQL database
user/password in `POSTGRES_USER`/`POSTGRES_PASSWORD`, and a distinct worker password
in `FETCHER_POSTGRES_PASSWORD` in the environment secret. The PostgreSQL host is
ignored by the connector. Start History first: it configures `fetcher_worker` and
the schema using a database user with role creation and schema privileges. Then
start Fetcher. Both `APP_BACKEND=hybrid` and `APP_BACKEND=postgres` are supported.
For `postgres`, first install PGMQ using the one-time SQL-only migration below;
Cloud SQL does not provide the PGMQ extension package.

Both Go modules and Docker builders use Go 1.26 or later. The final images include
CA certificates for the connector's Google API HTTPS requests. Private VM egress
must allow Google APIs on TCP 443 and Cloud SQL on TCP 3307.

After deployment check the History and Fetcher logs and create/read a history
record. Updating the secret alone does not update existing containers: download
the new environment and recreate the services. Previous PostgreSQL history is
not being migrated. Its VM still runs RabbitMQ and Redis.

## VM startup and deployment

Terraform stores a short bootstrap in `metadata["startup-script"]`. It keeps
non-secret deployment settings in `/etc/datamonitor/deploy.env`, obtains the
configured Git ref on first boot, and invokes `gcp-terra/scripts/deploy.sh` from
that checkout. Compose, Nginx, HTTPS setup and application source all come from
the same Git revision. Publish these files to the configured repository before
using the new bootstrap.

A regular reboot keeps the current checkout and existing images, refreshes the
environment secret, and runs Compose without rebuilding. Docker packages are
installed only when Docker/Compose is missing. A changed Git revision triggers
an image build; the deployment marker is written only after a successful start.
For an explicit update on the VM run:

```bash
sudo bash /opt/datamonitor/gcp-terra/scripts/deploy.sh --update
```

`compute.application.repo_branch` accepts a branch, tag or commit supported by
`git fetch origin REF`. Use a fixed tag or commit when a reproducible version is
required. Updating startup metadata does not execute the script automatically;
reboot the VM or run `sudo google_metadata_script_runner startup` after applying
an intentional metadata change.

In `hybrid` mode the `database` VM role starts RabbitMQ and Redis. In `postgres`
mode it stops these containers (keeping their volumes); neither is required. The local PostgreSQL
service remains in Compose for local development. Old PostgreSQL data is not
needed. Explicitly disable its old restart policy and stop it on the existing
VM; its data volumes are retained. The deployment scripts do not stop it for you.

The initial migration from `metadata_startup_script` to `metadata["startup-script"]`
requires special care: the checked Terraform plan currently proposes replacing
all five VMs because the old attribute is removed. Do not apply that plan until
VM data (especially RabbitMQ/Redis on the database VM) is backed up or a state
migration preserving the VMs has been reviewed. No apply was performed.

Startup receives only the service role, GCP project, environment secret ID,
HTTPS toggle, repository URL and Git ref. Cloudflare Tunnel is not supported by
the current deployment path. Cloud SQL connection settings come from Secret
Manager. No old PostgreSQL history needs to be imported into Cloud SQL.

## PGMQ SQL-only on Cloud SQL

The managed database uses upstream PGMQ **v1.13.1**, installed as SQL objects in
schema `pgmq`, not as a PostgreSQL extension. It is already installed in the
current Cloud SQL database; the one-time Python installer has been removed.
Its version/checksum remains recorded in `public.datamonitor_schema_migrations`.

For a new database, install the SQL file from the pinned upstream release once,
following the upstream SQL-only installation guide linked below. The verified
SHA-256 for `pgmq-extension/sql/pgmq.sql` from tag `v1.13.1` is
`e861fcbd8c602df70a00eb9d230b1a2f591860a2230b9a6084172e3eff463642`.
Run it transactionally with `psql -X --single-transaction -v ON_ERROR_STOP=1 -f pgmq.sql`
from a VM in the private network, using database-owner credentials. The raw SQL
file is for a fresh schema, not a repeatable upgrade. Startup never installs or
upgrades SQL-only PGMQ. No Python installer is required to run the applications.

History detects the PGMQ SQL API before attempting an extension install. Local
PostgreSQL images with the packaged extension still work. History creates the
`fetcher_tasks` queue and grants its worker the required table/function privileges.
Set `APP_BACKEND=postgres` in the shared environment secret, refresh and recreate
History, Fetcher and UI, then run deployment on the database VM to stop the unused
brokers. The applications must use the same mode.

Verify:

```sql
SELECT name, applied_at FROM public.datamonitor_schema_migrations;
SELECT * FROM pgmq.list_queues();
SELECT status, count(*) FROM fetcher_tasks GROUP BY status;
SELECT source, count(*), max(recorded_at) FROM history GROUP BY source;
```

In PostgreSQL mode History enqueues work through `pgmq.send`; Fetcher uses
`pgmq.read` and acknowledges completed messages with `pgmq.delete`. UI preferences
are stored in PostgreSQL. Cloud SQL remains private-only and Go Connector is
unchanged. Upstream installation guide:
https://github.com/pgmq/pgmq/blob/v1.13.1/INSTALLATION.md
