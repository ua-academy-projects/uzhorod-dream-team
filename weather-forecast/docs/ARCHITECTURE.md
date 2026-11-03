# Weather Forecast Architecture

The application runs on Ubuntu 24.04 VMs and a Cloud SQL for PostgreSQL
instance in Google Cloud. A bootstrap script prepares the project once.
Terraform creates the network, firewall rules, service accounts, secrets, VMs,
Cloud SQL and the DNS record. cloud-init prepares each VM on its first boot.
`infra/deploy/deploy.sh` builds the Docker images on the operator's machine,
copies them to the VMs, prepares the database and starts the containers.
Docker Compose is not used.

## Components

| Component | Address | Size | Ports | Responsibility |
| --- | --- | --- | --- | --- |
| `bastion` VM | `192.168.56.10` + static public IP | e2-micro | 22043 | SSH jump host and outbound NAT for the other VMs |
| `broker` VM | `192.168.56.15` | e2-small | 5672, 6379 | RabbitMQ and Redis; created only in `rabbitmq_redis` mode |
| `fetcher` VM | `192.168.56.12` | e2-micro | none published | Python Fetcher and queue worker |
| `history` VM | `192.168.56.13` | e2-small | 8002 | Go API, timers, queue consumer, database writer; runs database maintenance |
| `ui` VM | `192.168.56.14` + static public IP | e2-micro | 80, 443 | Nginx with TLS (Let's Encrypt), the static UI, proxies `/api/` to History |
| `tf-weather-db` Cloud SQL | private IP from the peering range | PostgreSQL 18, `db-f1-micro` | 5432 | Weather data, jobs, PGMQ queues, preferences |

The site is public at `https://app.weather-lab.pp.ua` (`app.public.domain`)
and is served by `ui`. Bastion is the separate entry point for administration
over SSH. The other VMs have no public addresses and reach the internet
through Bastion. Cloud SQL has no public address at all.

## Data flow

The browser sends requests only to Nginx. Nginx serves the static UI and
proxies `/api/` to History. History never calls Fetcher directly.

`WEATHER_BACKEND` selects the queue and preferences store at container startup.
In `rabbitmq_redis` mode the path is:

```text
browser -> Nginx -> History -> RabbitMQ weather.requests
                                      -> Fetcher -> Open-Meteo
                                      <- RabbitMQ weather.responses
                              History -> PostgreSQL (Cloud SQL)
                              History -> browser
```

In `postgres` mode messages travel through PostgreSQL instead:

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
The browser polls `GET /api/jobs/<request_id>` until the job is completed or
failed, then loads the saved weather. Fetcher responses are processed
asynchronously and validated before they are stored.

Temperature history uses a second job type. History checks the stored hourly
range at startup and every hour. It requests an initial 30-day backfill or
only missing ranges. Fetcher returns all requested ranges in one response;
History validates and stores the complete response in one transaction.

## Storage

PostgreSQL (Cloud SQL, database `weather_history`) contains:

- `weather_snapshots` for current weather records;
- `temperature_history` for hourly chart points;
- `weather_jobs` for queued, completed and failed jobs, tagged with their backend;
- PGMQ `weather_requests` and `weather_responses` queues in the `pgmq` schema;
- `weather_preferences` with `hstore` key/value preferences and expiry times;
- `schema_migrations` with the migrations already applied by the deploy script.

The `(city, weather_time)` key prevents duplicate current-weather rows. A
repeated collection updates the existing row and its `fetched_at` value.

Cloud SQL does not offer PGMQ as an extension, so PGMQ 1.13.0 is installed
with its SQL-only script (`pgmq.sql`, shipped in the `weather-postgres`
image). It is installed once, when the `pgmq` schema does not exist yet;
upgrading PGMQ needs a manual migration. `hstore` is a supported Cloud SQL
extension. Cloud SQL takes daily automatic backups.

RabbitMQ provides durable `weather.requests` and `weather.responses` queues.
Messages are persistent, publisher confirms are enabled, and consumers use
manual acknowledgements. History acknowledges a response only after the
database transaction succeeds. Fetcher acknowledges a request only after its
response is published successfully.

In `postgres` mode PGMQ manages delivery through `send`, `read`, `set_vt` and
`delete`. Fetcher reads one request with a 30-second visibility timeout,
renewed every 10 seconds. Publishing the response and acknowledging the
request happen in one transaction. History reads a response, saves the weather
and job result, and acknowledges the response in one transaction. Failed
transactions leave messages available for retry; job IDs prevent duplicate
results. Idle workers poll once per second.

Redis stores only UI theme preferences in `rabbitmq_redis` mode; `postgres`
mode uses `hstore` values in `weather_preferences` instead. The browser keeps
a random `weather_session` cookie. The cookie and the stored preferences
expire after 30 days and are renewed when preferences are read or saved. A
missing or expired entry returns the default light theme. Redis failure does
not remove weather data from PostgreSQL.

Both application images support both modes. Switching is described in
[BACKENDS.md](BACKENDS.md).

## Configuration

Nothing secret or personal is kept in the repository.

| Where | Content |
| --- | --- |
| `~/.config/weather-forecast/deployment.json` | all non-secret settings: project name and prefix, bootstrap (APIs, Terraform service account roles, state prefix), networks, subnets, firewall rules, service accounts, secret names and their readers, VMs, Cloud SQL, application settings, SSH users and public keys |
| `~/.config/weather-forecast/local.env` (mode `600`) | `PROJECT_ID`, `BILLING_ACCOUNT`, `GOOGLE_APPLICATION_CREDENTIALS` (path to the Terraform key), `MY_IP_CIDR`, `WEATHER_SSH_KEY`, `WEATHER_SSH_USER` |
| Secret Manager | passwords and the Cloudflare API token |

`WEATHER_CONFIG` and `WEATHER_ENV` override the paths for the scripts;
Terraform reads the config from `var.config_path`.

VM settings use defaults with overrides: `vms.defaults` holds the common
values, and each entry in `vms.instances` sets only what differs (address,
machine type, disk size, role, service account). A VM with
`only_for_backend` is created only when `app.backend` matches. A VM's network
is the network of its subnet.

`app.public` describes the public site (domain, Cloudflare zone, host,
Let's Encrypt staging). `app.services` sets the VM and, for third-party
images, the image of each service.

## Bootstrap

`infra/bootstrap/bootstrap.sh` runs once under the operator's own Google
account (`gcloud auth login`) and is safe to repeat. It:

1. creates the project if it does not exist and links the billing account;
2. enables the APIs from `bootstrap.apis`;
3. creates the `terraform` service account and grants it the roles from
   `bootstrap.terraform_sa.roles`;
4. creates the state bucket `<PROJECT_ID>-tfstate` (uniform access, public
   access prevention, versioning) and grants the service account
   `roles/storage.objectAdmin` on it;
5. creates a key for the service account at `GOOGLE_APPLICATION_CREDENTIALS`
   (mode `600`) if the file is missing or empty;
6. runs `terraform init` with the GCS backend under that key, migrating a local
   state if there is one.

Organizations created by Google enforce
`iam.disableServiceAccountKeyCreation`. The constraint has to be turned off for
the project once (Organization Policies) before step 5 can succeed.

## Infrastructure

`infra/terraform/` is the root module. `providers.tf` reads the config once,
sets the project (`TF_VAR_project_id`), region and zone, and declares the GCS
backend. `main.tf` passes the whole config to seven local modules and wires
their outputs together:

```text
network ──networks──► firewall
   ├──networks, subnets──► vms ◄──emails── service_accounts ──emails──► secrets
   │                        └──external_ips──► dns
   └──network_ids──► cloudsql
```

| Module | Creates |
| --- | --- |
| `network` | one VPC per entry in `networks`, one subnet per entry in `subnets` |
| `firewall` | `firewall.external` rules (source: `my_ip_cidr` unless the rule sets `source_ranges`) and `firewall.internal` rules (source and target network tags) |
| `service_accounts` | one service account per entry and its project roles |
| `secrets` | one Secret Manager secret per entry in `secrets` and `secretAccessor` for each listed reader; no secret values |
| `vms` | VMs, static IPs of VMs with `public_ip`, additional disks, the egress route through Bastion, cloud-init user data |
| `dns` | the Cloudflare A record `app.public.domain` pointing to the UI's public IP |
| `cloudsql` | the `VPC_PEERING` address range, the Service Networking connection, the Cloud SQL instance (no public IP, encrypted connections only) and the database |

Each VM has the network tag of its own name. VMs without a public IP also get
the `via-bastion` tag, which the egress route and firewall rules refer to. A
VM with its own public IP (Bastion, UI) uses the default internet gateway, so
replies to incoming connections leave from the address they arrived at. Ingress
not allowed by a rule is denied by GCP's implied rule.

Each VM runs under its own service account instead of the default Compute
Engine account. All of them have `roles/logging.logWriter` and
`roles/monitoring.metricWriter`; access to a secret is granted per secret to
the accounts listed in its `accessors`.

Cloud SQL is reached through Private Service Access: Terraform reserves an
internal range in the VPC and connects it to Google's service network before
the instance is created. The instance gets only a private IP from that range
and rejects unencrypted connections. VPC firewall rules do not apply to it;
access is limited by the private network and PostgreSQL passwords. Database
users are not managed by Terraform, so their passwords never reach the state.

Additional disks are listed per VM (`disks`), created as separate resources
and attached as `disk-1`, `disk-2`, … (`/dev/disk/by-id/google-disk-N`).
They are attached but not formatted or mounted.

### First boot (cloud-init)

Each VM receives a cloud-config in its `user-data` metadata. cloud-init runs
it once per VM:

- **users**: Bastion gets only `jump` (no shell, keys of everyone in
  `ssh.public_keys`); nodes get a personal account with sudo for each key;
- **files**: SSH socket on port 22043, sshd settings, and on Bastion the
  nftables NAT rules and `net.ipv4.ip_forward = 1`; on nodes Docker's
  `daemon.json` with MTU 1460;
- **command**: `modules/vms/scripts/setup.sh bastion|node`. It checks the sshd
  configuration (`sshd -t`) before restarting SSH. Bastion enables nftables.
  Nodes wait for internet access through Bastion and install `docker.io`.

Changing user data does not reconfigure a running VM: Terraform updates the
metadata, but cloud-init does not run again. Recreate the VM to apply it.

### Running Terraform

The state is kept in the bucket `<PROJECT_ID>-tfstate` under the prefix
`weather-forecast`. Terraform works under the `terraform` service account key.
The Cloudflare provider reads its token from the environment, taken from
Secret Manager:

```bash
set -a; source ~/.config/weather-forecast/local.env; set +a
export TF_VAR_project_id=$PROJECT_ID TF_VAR_my_ip_cidr=$MY_IP_CIDR
export CLOUDFLARE_API_TOKEN=$(gcloud secrets versions access latest --secret=tf-weather-cloudflare-api-token)
terraform -chdir=infra/terraform plan
terraform -chdir=infra/terraform apply
```

Outputs: `external_ips`, `internal_ips`, `secrets` (full secret names) and
`cloudsql` (private IP and instance name).

## Network and access

| Rule | From | To | Port |
| --- | --- | --- | --- |
| `ext-ssh-bastion` | `my_ip_cidr` | `bastion` | tcp 22043 |
| `ext-web` | `0.0.0.0/0` | `ui` | tcp 80, 443 |
| `int-egress-gateway` | `via-bastion` | `bastion` | all |
| `int-ssh-nodes` | `bastion` | `via-bastion`, `ui` | tcp 22043 |
| `int-rabbitmq` | `history`, `fetcher` | `broker` | tcp 5672 |
| `int-redis` | `history` | `broker` | tcp 6379 |
| `int-history-api` | `ui` | `history` | tcp 8002 |

Only the UI is open to the internet, and only on 80 and 443. Port 80 answers
with a 308 redirect to HTTPS. Nodes without a public IP send outbound traffic
through the route `0.0.0.0/0` (priority 800, tag `via-bastion`) to Bastion,
which masquerades it with nftables. Bastion itself uses the default internet
gateway. Traffic to Cloud SQL uses the more specific peering route and does not
pass through Bastion.

SSH always goes through Bastion:

```text
operator -> jump@<bastion public IP>:22043 -> <user>@192.168.56.12-15:22043
```

- Bastion accepts only `jump`, password login is disabled, sessions are
  disabled (`MaxSessions 0`, `PermitTTY no`), and forwarding is limited to
  port 22043 (`PermitOpen *:22043`). It cannot be used as an internet proxy or
  to reach the metadata server.
- Nodes accept only the personal accounts and only from Bastion's address.
- Project-wide SSH keys are blocked on every VM.

Example `~/.ssh/config`:

```text
Host gcp-tf-bastion
    HostName <bastion public IP>
    User jump

Host gcp-tf-history
    HostName 192.168.56.13
    ProxyJump gcp-tf-bastion

Host gcp-tf-*
    User <your login from ssh.public_keys>
    Port 22043
    IdentityFile ~/.ssh/weather_vm
    IdentitiesOnly yes
```

After VMs are recreated, update Bastion's address and remove the old host
keys from `var/deploy/known_hosts`.

## Deployment

`infra/deploy/deploy.sh` is idempotent. A repeated run with no changes leaves
every container running and the database untouched. It needs Docker, `gcloud`,
`jq`, `ssh` and Terraform locally, membership in the `docker` group, the config
and `local.env`. `common.sh` reads both, gets Bastion's address from
`terraform output` and connects to each VM through `jump`. Secrets are read
from Secret Manager under the operator's `gcloud` account; their names come
from `terraform output secrets`.

Steps:

1. Build `weather-postgres`, `weather-fetcher`, `weather-history` and
   `weather-ui` for `linux/amd64` without provenance attestations, so an
   unchanged source gives the same image ID. In `rabbitmq_redis` mode also
   pull the RabbitMQ and Redis images from `app.services`.
2. Wait until cloud-init has finished on every target VM.
3. Copy an image to a VM only when its image ID differs.
4. **Database** from `history`, with one-off containers of `weather-postgres`
   (it carries `psql` and `pgmq.sql`). The `postgres` password is written to
   `/etc/weather-forecast/pgpass` (mode `600`) and set on Cloud SQL with
   `gcloud sql users set-password` only when the login fails. Then: install
   PGMQ if the `pgmq` schema is missing, create `hstore`, apply each migration
   once (recorded in `schema_migrations`), set the `weather_app` and
   `weather_fetcher` roles and their privileges.
5. **RabbitMQ and Redis** on `broker` in `rabbitmq_redis` mode.
6. **Fetcher** and **History** with their environment files; database URLs use
   `sslmode=require`.
7. **Certificate** on `ui`: Certbot (`app.services.certbot.image`) gets a Let's
   Encrypt certificate for `app.public.domain` with the DNS-01 challenge
   through the Cloudflare API, so no port has to be open for validation. The
   certificate is kept in the `weather-letsencrypt` volume;
   `--keep-until-expiring` makes a repeated run a no-op. With
   `app.public.letsencrypt_staging: true` it uses the Let's Encrypt staging CA
   under a separate certificate name. A systemd timer
   (`weather-certbot-renew.timer`) renews it daily when needed and reloads
   Nginx.
8. **UI** with the rendered Nginx configuration: HTTPS on 443, redirect 308
   from 80.

A container is replaced only when its image, environment file, configuration
file or run arguments change. Containers use host networking and
`--restart unless-stopped`.

Files on the VMs are stored under `/etc/weather-forecast/`. Environment files,
`pgpass`, `cloudflare.ini` and `redis.conf` have mode `600`. Secrets:

| Secret (`tf-weather-…`) | Used by | Readers in Secret Manager |
| --- | --- | --- |
| `postgres-admin-password` | deploy script, database maintenance | operator only |
| `db-password` | History (`weather_app`) | `history` |
| `fetcher-db-password` | Fetcher (`weather_fetcher`, `postgres` mode) | `fetcher` |
| `rabbitmq-password` | RabbitMQ, History, Fetcher (`rabbitmq_redis` mode) | `broker`, `history`, `fetcher` |
| `redis-password` | Redis, History (`rabbitmq_redis` mode) | `broker`, `history` |
| `cloudflare-api-token` | Certbot on `ui`, Terraform | `ui` |

Values are added by hand (`gcloud secrets versions add <name> --data-file=-`
or the console) and never pass through Terraform. Passwords must contain at
least 16 characters from `A-Z a-z 0-9 . _ ~ -`, so they fit into connection
URLs without escaping.

RabbitMQ and Redis data live in Docker volumes on `broker`'s boot disk, so
recreating or removing that VM deletes them.

## Logs

Containers use Docker's default logging, read with
`ssh gcp-tf-<vm> 'sudo docker logs <container>'`. cloud-init output is in
`/var/log/cloud-init-output.log` on each VM. The Ops Agent is not installed
yet, so VM and container logs are not sent to Cloud Logging.

## Source layout

```text
services/
  fetcher/                Python Fetcher, tests
  history/                Go History service
  ui/public/              Static HTML, CSS, JavaScript
infra/
  bootstrap/              bootstrap.sh
  postgres/               Database tools image (psql, PGMQ SQL), migrations/
  terraform/              Root module
    modules/
      network/
      firewall/
      service_accounts/
      secrets/
      vms/                cloud-init, scripts/setup.sh, templates/
      dns/
      cloudsql/
  deploy/                 deploy.sh, common.sh, templates/ (nginx, rabbitmq)
docs/                     Project documentation
var/deploy/               known_hosts (ignored)
```

From the project root, run Python tests with
`.venv/bin/python -m pytest services/fetcher/tests`. For Go, change to
`services/history/`, then run `go test ./...` and
`go build -o bin/history ./cmd/history`. Local startup uses
`python -m fetcher` from `services/fetcher/` and `go run ./cmd/history` from
`services/history/`, with the chosen backend environment configured.
History's default local UI directory is `../ui/public`; deployed History
containers use `HISTORY_SERVE_UI=false` and the separate Nginx VM.
