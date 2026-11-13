# my-ansible

Deployment of the OSM infrastructure on GCP (after `terraform apply`). Everything Ansible installs on the VMs lives in the
**`ian.main`** collection (`collections/ansible_collections/ian/main/`), and this directory is the project it is run from: config, inventory, secrets.

## Principles

1. **No `group_vars` / `host_vars`.** Variables come from three places, and each one is visible in the code:
   - `../config.json` via the `ian.main.osm_config` lookup (ports, internal IPs, domain, versions, service env);
   - the role's `defaults/main.yml` (whatever is not in the config);
   - `-e @secrets/vault.yml` (passwords), which the playbook maps to role variables in `vars/secrets.yml`.
2. **Internal IPs always come from `config.json`** (`instances.<name>.internal_ip`), not from the API. From the GCP API the inventory takes only
   what the config cannot know: the list of RUNNING VMs and public addresses (`external_ip` of bastion and frontend).
3. **VM names in the inventory = keys of `config.instances`** (`bastion`, `frontend`, `fetcher`, `history`, `database`, `querycache`).
   That is why the `artifact_service` role takes the service name from `inventory_hostname`.

## Structure

```
my-ansible/
├── ansible.cfg                  config (run commands from this directory)
├── inventory/gcp_osm.yml        dynamic inventory (projects = project_id from config.json)
├── secrets/
│   ├── vault.yml                encrypted vault (git-ignored)
│   └── vault.yml.example        which keys it must contain
├── .vault_pass                  vault password (git-ignored, you create it yourself)
└── collections/ansible_collections/ian/main/   THE ian.main COLLECTION: the only place where code lives
    ├── galaxy.yml, meta/        identity, dependencies, minimum ansible-core version
    ├── plugins/lookup/osm_config.py   reads config.json
    ├── plugins/inventory/gcp_osm.py   gcp_compute wrapper: projects from config.json
    ├── plugins/filter/urlsafe.py      escapes passwords for URLs
    ├── roles/                   common, postgres, querycache, queue_env, artifact_service,
    │                            service_handlers, frontend, ops_agent_config, overpass
    └── playbooks/               site, deploy_binaries, deploy_frontend, issue_certificate,
        └── vars/                switch_backend, assert_project
                                 connection.yml (ProxyJump), secrets.yml (vault mapping)
```

The collection sits directly at the strict path `<collections_path>/ansible_collections/<namespace>/<name>/` (`collections_path = collections` in `ansible.cfg`),
so no symlinks or reinstallation are needed. Dependency collections (`ansible-galaxy collection install -p collections …`) are installed next to it and ignored by git.

## Setup (one time)

```bash
cd infra/my-ansible

# 1. Tools: ansible-core >= 2.18 and the dependency collections (defined by the collection's galaxy.yml)
ansible-galaxy collection install community.general community.postgresql community.rabbitmq google.cloud
pip install google-auth requests          # for the gcp_compute inventory plugin

# 2. Credentials for the dynamic inventory (requires the compute.instances.list permission)
gcloud auth application-default login

# 4. Secrets
cp secrets/vault.yml.example secrets/vault.yml      # fill in, then encrypt:
echo '<password>' > .vault_pass && chmod 600 .vault_pass
ansible-vault encrypt secrets/vault.yml
```

`ansible.cfg` sets `vault_password_file = .vault_pass`, so **without this file every Ansible command fails** in this directory.
The SSH user is set by `remote_user` in `ansible.cfg` (overridden by `ANSIBLE_REMOTE_USER`).

## Running

Playbooks are run by name, no full path needed: `ansible-playbook ian.main.<playbook>`.
The directory must be `infra/my-ansible/`, because `ansible.cfg` (and `.vault_pass`) are picked up from there. Order on an empty project:
`terraform apply` → `../upload-artifacts.sh` → `ian.main.site`.

Two things you will need in almost every command (used below as `$CSQL` and `$V`):

```bash
CSQL=$(terraform -chdir=.. output -raw cloudsql_private_ip)     # private IP of Cloud SQL (backend 1)
V="-e @secrets/vault.yml"
```

### Command reference

**Overview (changes nothing)**
```bash
ansible-inventory --graph                          # which VMs are visible (6 of them); empty = no VMs or no access to GCP
ansible-inventory --host fetcher                   # inventory variables for a host
ansible-doc -t lookup ian.main.osm_config          # lookup plugin documentation
ansible-doc -t inventory ian.main.gcp_osm          # inventory plugin documentation
ansible-galaxy collection list | grep ian.main     # the collection is picked up
ansible-playbook ian.main.site $V -e queue_env_database_host=$CSQL --list-tasks --list-hosts   # what will run and where
ansible-playbook ian.main.site $V -e queue_env_database_host=$CSQL --syntax-check
ansible fetcher -m ansible.builtin.ping -e @collections/ansible_collections/ian/main/playbooks/vars/connection.yml   # connectivity (ad hoc needs ProxyJump)
```

**Full deployment: `ian.main.site`** (backend = `active_backend` from `config.json`, currently 1: Cloud SQL + RabbitMQ + Redis)
```bash
ansible-playbook ian.main.site $V -e queue_env_database_host=$CSQL --check --diff           # preview
ansible-playbook ian.main.site $V -e queue_env_database_host=$CSQL -e frontend_certbot_staging=true   # first time
ansible-playbook ian.main.site $V -e queue_env_database_host=$CSQL                          # afterwards
ansible-playbook ian.main.site $V -e queue_env_database_host=$CSQL --tags services          # only fetcher and history
ansible-playbook ian.main.site $V -e queue_env_database_host=$CSQL --limit fetcher          # only one host
```
Tags: `querycache`, `services`, `frontend`, `certs`, `nginx`, `static`, `database`, `monitoring`, `overpass`.
**Roles needed by only one backend run only for that backend:** Postgres on the `database` VM (role `postgres`) only for backend 2,
RabbitMQ and Redis (role `querycache`) only for backend 1. For the other backend `site` does not run them at all, even with `--tags database` or `--tags querycache`.
Backend 2 is deployed like this (one-off, without changing `config.json`):
```bash
ansible-playbook ian.main.site $V -e backend=2                                     # Postgres + pgmq + hstore, services on pgmq
ansible-playbook ian.main.site $V -e backend=2 --tags database --limit database    # Postgres only
```

**Binaries and static files** (after `../upload-artifacts.sh ...`)
```bash
../upload-artifacts.sh all                  # or fetcher | history | frontend
ansible-playbook ian.main.deploy_binaries $V       # fetcher + history; restarts only if the binary changed
ansible-playbook ian.main.deploy_frontend          # static files, no vault needed
```

**Switching the backend: `ian.main.switch_backend`** (see "Backends")
```bash
ansible-playbook ian.main.switch_backend $V -e backend=1 -e queue_env_database_host=$CSQL
ansible-playbook ian.main.switch_backend $V -e backend=2
```

**Frontend: certificate** (the domain's A record is created by Terraform, `modules/dns`)
```bash
ansible-playbook ian.main.issue_certificate $V -e frontend_certbot_staging=true   # staging (first time)
ansible-playbook ian.main.issue_certificate $V                                    # production
```

**Useful flags:** `--check --diff` (dry run), `--limit <vm>`, `--tags/--skip-tags`, `-v`/`-vvv` (details), `-e key=value` (override a role variable),
`--start-at-task "<name>"`, `--step`. Secrets (`no_log`) are hidden in the output. The `ian.main.assert_project` playbook does not need to be run separately, every playbook imports it.

| Playbook | What it does | Vault needed |
|---|---|---|
| `ian.main.site` | packages, fetcher/history, frontend; RabbitMQ/Redis only for backend 1, Postgres on a VM only for backend 2 | yes |
| `ian.main.deploy_binaries` | new fetcher/history binaries (after `upload-artifacts.sh`), restarts only on change | yes |
| `ian.main.deploy_frontend` | new static files (after `upload-artifacts.sh frontend`) | no |
| `ian.main.issue_certificate` | Let's Encrypt certificate (DNS-01); idempotent: certbot runs only when there is no certificate, it expires within 30 days, or the type (staging/production) or domain changed | yes |
| `ian.main.switch_backend` | switching backends (see "Backends") | yes |
| `ian.main.assert_project` | guard (imported first in every playbook) | no |

> The backend choice is stored in `config.json` (`active_backend`), so `site` does not reset it. `-e backend=N` applies to a single run only.

## Monitoring and Overpass

- The Ops Agent on the VMs is installed by an OS policy from Terraform (`modules/ops_agent`); Ansible only puts its config in place. Tag `monitoring`, role `ops_agent_config`:
  `history` gets the `postgresql` receiver (rows-per-minute metric by history table, `osm` dashboard), `querycache` (backend 1) gets `rabbitmq` and `redis`.
  The role stops with an explanation if the agent is not installed yet (up to 10 minutes after the VM starts).
- On `frontend`, `cert-expiry-check` runs daily (the origin certificate, not Cloudflare's), and on `overpassapi` `overpass-health-check` runs every minute;
  both write to syslog, Cloud Logging counts `WARN`/`FAIL` lines, and the alerts are defined in `config.json monitoring.log_alerts`.
- All metric thresholds (disk, memory, LA, Cloud SQL, queues) are in `config.json monitoring.metric_alerts`; adding an alert means adding an entry there and running `terraform apply`.
- Overpass (tag `overpass`, role `overpass`): Docker + `wiktorn/overpass-api`, a map of Ukraine from Geofabrik. The first import takes hours and the role does not wait for it;
  progress: `journalctl -u overpass -f` on `overpassapi`, completion = the file `/var/lib/overpass/init_done`. After the import, `ian.main.site --tags services` picks up the new `OVERPASS_URLS` in fetcher.

## Backends

Backends are described in `config.json` in the `backends` block (keys `1` and `2`); each has `description`, `queue`, `cache` (or `null`), `database` and `secrets`
(names of `vault.yml` keys). The `queue_env` role builds `QUEUE_URL`, `REDIS_URL` and `DATABASE_URL` from this; it has no branches for a specific backend.

| `backend` | Queue | Cache | History database (`DATABASE_URL`) |
|---|---|---|---|
| `1` (currently `active_backend`) | RabbitMQ on `querycache` | Redis on `querycache` | **Cloud SQL**, private IP via PSA peering, `sslmode=require` |
| `2` | pgmq on the `database` VM | hstore on the `database` VM | Postgres on the `database` VM |

`DATABASE_URL` for history is written by the `queue_env` role to `/etc/osm/queue.env` together with `QUEUE_URL`, so `switch_backend` changes everything at once.
The Cloud SQL IP is allocated from the PSA range and is not in `config.json`, so for backend 1 it is passed explicitly (`-e queue_env_database_host=$CSQL`).

```bash
ansible-playbook ian.main.switch_backend -e @secrets/vault.yml -e backend=1 \
  -e queue_env_database_host=$(terraform -chdir=.. output -raw cloudsql_private_ip)
ansible-playbook ian.main.switch_backend -e @secrets/vault.yml -e backend=2
```

To make the choice permanent, change `active_backend` in `config.json`. Data is not migrated between backends.
The `postgres` and `querycache` roles install only the component the backend needs (see "Full deployment"); `site` does not remove what was already installed for the other backend.

## Where variables come from

| What | From where |
|---|---|
| ports, domain, pgmq versions, service env, bucket | `../config.json` via `lookup('ian.main.osm_config', 'services.fetcher.ports.0')`, set in the roles' `defaults/main.yml` |
| internal IPs | `config.json` → `instances.<name>.internal_ip` |
| `ansible_host`, ProxyJump via bastion | `playbooks/vars/connection.yml` (included in every play via `vars_files`) |
| public IP of bastion for SSH | inventory (`external_ip`) |
| passwords, Cloudflare token | `secrets/vault.yml` → `playbooks/vars/secrets.yml` → role variables |
| `QUEUE_URL`, `REDIS_URL`, `DATABASE_URL` | built in `queue_env` from `config.json backends.<N>`; passwords are taken from the vault by the names in `backends.<N>.secrets` |
| backend number | `-e backend=N`, otherwise `config.json active_backend` (`playbooks/vars/connection.yml`) |

Keys in `vault.yml`: `vault_pgmq_password`, `vault_history_password` (history on the `database` VM), `vault_cloudsql_history_password` (history in Cloud SQL, must match `TF_VAR_history_pass`), `vault_rabbit_user`, `vault_rabbit_password`,
`vault_redis_password`, `vault_cloudflare_api_token`.

## How a role is structured

- Variables have the **role name as a prefix** (`postgres_port`, `frontend_domain`): role variables are global within a play.
- `defaults/main.yml` is the public interface (can be overridden); `vars/main.yml` holds internal constants.
- `meta/argument_specs.yml` holds types, `choices`, `required`, `no_log`; it is validated **before** the tasks run.
  Conditional requirement (`required_if`) is not supported at the role level, so there is an `assert` in tasks for it.
- Secrets in `defaults` are commented out (no default value), so a forgotten password gives an error rather than an empty string.
- The `frontend` role has several entry points: `tasks_from: static | certs | nginx`.
- If a new role is added to this directory, its FQCN will be `ian.main.<name>` (names use only `_`, no hyphens).

## Troubleshooting

| Symptom | Cause / solution |
|---|---|
| `The vault password file … .vault_pass was not found` | create `.vault_pass` (see "Setup") |
| inventory is empty (`@all: |--@ungrouped:`) | the VMs are not created yet (`terraform apply`), or there is no access to GCP (`gcloud auth application-default login`). `projects` is injected by the `ian.main.gcp_osm` plugin from `project_id` in `config.json` (`gcp_compute` itself does not template `projects` and does not take the project from `gcloud config`). The `assert_project` guard stops the run with an explanation |
| `'vault_… ' is undefined` | `-e @secrets/vault.yml` was not passed |
| SSH does not connect | your IP must be in `ssh.bastion_from` (`config.json`), and your key in OS Login (`../keys.sh`) |
| browser: "Not secure" | the certificate is still staging: `ian.main.issue_certificate -e @secrets/vault.yml` (without `frontend_certbot_staging`), the role replaces staging with production by itself |
| `ansible` ad hoc does not find the host | without `group_vars` ad hoc does not know ProxyJump; add `-e @collections/ansible_collections/ian/main/playbooks/vars/connection.yml` |
