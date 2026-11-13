# iss.tracker

Roles of the ISS position tracker: project checks, the bastion and app hosts, and the app deploy with Docker Compose. Generic OS roles live in `iss.platform`; these roles call them with project values.

Role `config` reads `config.json` with `include_vars` into `iss_config` (file from `iss_config_file`, default env `ISS_CONFIG`, else `config.json` next to the `ansible` directory) and checks it; it runs first in every play. Every other role takes the whole config as `iss_config` (`type: dict, required: true`) and derives what it needs in its own `vars/main.yml`; there are no `group_vars` and no extra vars. Nothing comes from Terraform: VM addresses come from the inventory, the Cloud SQL instance from the Cloud SQL Admin API (`iss.platform.gce_sql_instance_info`, label `iss-prefix`).

## Inventory contract

| Name | Meaning |
|---|---|
| group `bastion` | exactly one host, the SSH bastion |
| group `app` | every app VM |
| group `<key>` | the VM of each key of `iss_config.vms` (`db`, `history`, `fetcher`, `ui`); `db` only when a backend needs it |
| `gce_internal_ip` | the VM's internal IP (set by `iss.platform.gce`) |
| `ansible_host`, `ansible_user`, `ansible_port`, `ansible_ssh_private_key_file`, `ansible_ssh_common_args` | connection; app VMs go through the bastion with `ProxyCommand` |

## Roles

| Role | Entry points | What it does |
|---|---|---|
| `config` | `main` | `include_vars` of `config.json` as `iss_config`, validation against the project's `config.schema.json` with `ansible.utils.validate` (draft 2020-12), then the one rule a schema cannot express: exactly one bastion. Validation runs once on localhost |
| `bastion` | `main`, `os_update`, `unban`, `revoke` | bastion configuration through a temporary admin key (`iss.platform.gce_temp_admin`, guest agent, sshd, fail2ban, Ops Agent); the key is removed in `always` |
| `app_host` | `main` | waits for cloud-init, sshd, Docker, Ops Agent with the container log pipeline (nginx JSON parsed on `ui`) |
| `os_update` | `main` | `apt` upgrade, reboot only with `/var/run/reboot-required` |
| `app_deploy` | `render`, `files`, `up` | `render` (localhost): renders and checks the `compose.yaml` and secret names of the VM; `files`: ships changed images, uploads `compose.yaml`, `secrets.list`, `iss-run`, `iss-compose`, `iss.service`, removes an old `.env`, checks that the VM can read its secrets; `up`: `iss-compose up -d --remove-orphans`, prunes images |
| `postgres` | `container_prepare`, `container`, `cloudsql` | Postgres setup for each mode with `community.postgresql` |
| `letsencrypt` | `restore`, `backup` | keeps the Let's Encrypt state in Secret Manager |

`deploy.yml` lists these entry points in order for each VM (see the project README).

## Variables

`app_deploy` `render` sets host facts: `app_deploy_compose` (the source compose file with every non-secret `${NAME…}` replaced by its value, services of inactive profiles and the `profiles` keys removed; built by the filter `iss.tracker.compose_render`), `app_deploy_secret_names` (secrets the kept services reference, for `secrets.list`), `app_deploy_vars` (non-secret values) and `app_deploy_secret_values` (`no_log`; read on localhost only to check them and for role `postgres`, never sent to the VM as a file). Inputs: `app_deploy_secrets` (dict that replaces the Secret Manager lookup, for tests), `app_deploy_cloudsql_instances` (list that replaces the Cloud SQL lookup, for tests), `app_deploy_compose_dir` (`<project>/deploy`). `*_IP` values come from `hostvars[<prefix>-<key>].gce_internal_ip`; `DB_IP` is empty when `db` is not needed. It fails when a needed VM is not in the inventory, when mode `cloudsql` does not find exactly one RUNNABLE instance, and on secret names inside `app`, empty values, empty needed secrets, and `$`, whitespace, `#` or quotes in any value.

`app_deploy`:

| Variable | Default |
|---|---|
| `app_deploy_dir` | `/opt/iss` |
| `app_deploy_bin_dir` | `/usr/local/sbin` (`iss-run`, `iss-compose`) |
| `app_deploy_services_dir` | `<project>/services` |
| `app_deploy_image_cache` | `$ISS_ANSIBLE_CACHE/images` |
| `app_deploy_compose`, `app_deploy_secret_names` | set by `render` |
| `app_deploy_iss_run_env` | `{}` (test endpoints for `iss-run`, never secrets) |

An image is copied only when its content hash (sha256 of `.Config` and `.RootFS.Layers`) differs from `/opt/iss/images/<image>.id` or the image is missing. Services no longer in `compose.yaml` are removed by `--remove-orphans`.

`iss-run` (Python standard library) reads `/opt/iss/secrets.list`, gets a token for the VM's service account from the metadata server, reads each secret's latest version from Secret Manager and runs its arguments with the values added to the environment. A missing, unreadable or empty secret, or one with `$`, whitespace, `#` or a quote, stops it with `iss-run: <NAME>: <reason>` and exit code 1; values are never printed. `iss.service` runs `iss-compose up -d --remove-orphans` at boot and on `systemctl restart iss`.

`postgres` (values from `app_deploy` `render` by default; the modules run on the VM with `python3-psycopg2`; module arguments, passwords included, travel on stdin with pipelining; password tasks are `no_log`):

| Variable | Default |
|---|---|
| `postgres_dir` | `/opt/iss` |
| `postgres_socket_dir` | `/opt/iss/postgres/run` (mounted as `/var/run/postgresql` in the postgres container) |
| `postgres_install_psycopg` | `true` |
| `postgres_file_owner` | `root` |
| `postgres_env` | `app_deploy_vars` |
| `postgres_compose` | `/usr/local/sbin/iss-compose` (starts the proxy, stops and starts `history`) |
| `postgres_pgmq_version` | `PGMQ_VERSION` |
| `postgres_pgmq_sql` | `$ISS_ANSIBLE_CACHE/pgmq/pgmq-<version>.sql` |
| `postgres_admin_password`, `postgres_history_password`, `postgres_fetcher_password` | from `app_deploy_secret_values` |

- `container_prepare` (before `compose up` on `db`): creates the socket directory.
- `container` (after `compose up` on `db`, over the socket): database, roles `postgres`, `history`, `fetcher` with their passwords, the pgmq extension (another version dropped first), hstore, pg_cron, grants and pg_cron jobs.
- `cloudsql` (before `compose up` on `history`, through the proxy on `127.0.0.1`): sets the `postgres` password through the Cloud SQL Admin API only when the login fails, installs pgmq as a script when the schema comment differs (Cloud SQL has no pgmq extension), hstore, pg_cron, grants and pg_cron jobs. A failed setup starts `history` again and fails the play.

`letsencrypt`:

| Variable | Default |
|---|---|
| `letsencrypt_dir` | `/opt/iss` |
| `letsencrypt_volume` | `iss_letsencrypt` |
| `letsencrypt_image` | `alpine:3.22` |
| `letsencrypt_host` | `UI_HOST` |
| `letsencrypt_state` | `LETSENCRYPT_STATE` secret, empty when it has no version |
| `letsencrypt_save` | `true` |
| `letsencrypt_limit` | `65536` bytes |
| `letsencrypt_gcloud` | `gcloud` |

`restore` creates the volume and fills it from the saved state only when it has no certificate for the host. `backup` packs the volume deterministically and adds a secret version only when the archive changed, keeping the two newest. certbot gets `CLOUDFLARE_API_TOKEN` in its environment and writes `/secrets/cloudflare.ini` into a tmpfs inside its container.

## Warnings

- Switching `POSTGRES_BACKEND` from `cloudsql` to `container` deletes the Cloud SQL instance with its data (`tf.sh apply`); the other way leaves the `postgres18-data` volume on `db`. Data is not moved.
- A backend change that makes `db` unneeded deletes the `db` VM with its Redis, RabbitMQ and Postgres data on the next `tf.sh apply`.
- In mode `container` apps connect to Postgres with `sslmode=disable` across the VPC, like Redis and RabbitMQ; passwords are protected by `scram-sha-256`, the data is not.
- Changing `postgres.pgmq_version` reinstalls pgmq and loses queued messages; `history` and `fetcher` are recreated through their `iss.pgmq-version` label.

## Migrating a stand deployed with `deploy.sh`

1. In `config.json` move `cloudsql.database_name` and `cloudsql.pgmq_version` to `postgres`, add `postgres.pg_cron_version`, `app.POSTGRES_BACKEND: "cloudsql"`, `monitoring.ops_agent` and `POSTGRES_PORT` in the `history → db` and `fetcher → db` firewall rules.
2. `./scripts/bootstrap.sh`.
3. `./scripts/tf.sh init`, `./scripts/tf.sh plan` shows only moves and additions, then `apply`.
4. `./scripts/ansible.sh site.yml`.
