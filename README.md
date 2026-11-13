# ISS position tracker on GCP

Four or five Ubuntu 26.04 VMs on Google Cloud (plus a Cloud SQL for PostgreSQL instance when you choose it) built with Terraform; Ansible configures the VMs and deploys the app as Docker Compose projects. Ansible needs only `config.json`, the service account key and the GCP APIs, not the Terraform state, so the two can run on different machines.

| VM | Containers | Role |
|---|---|---|
| `iss-jump` | none | SSH bastion, fail2ban, the only VM with an external IP |
| `iss-db` | redis, rabbitmq, postgres (container mode) | sessions, queues, Postgres in container mode; created only when one of them is used |
| `iss-fetcher` | fetcher, cloudsql-proxy (Cloud SQL with Postgres queue modes) | polls wheretheiss.at, publishes positions |
| `iss-history` | history, cloudsql-proxy (Cloud SQL) | consumes positions, HTTP API |
| `iss-ui` | ui (nginx), certbot, cloudflared | web UI `https://iss.<zone>`, only through Cloudflare Tunnel |

Postgres is chosen with `app.POSTGRES_BACKEND`, like the queue and session backends:

- `cloudsql`: Cloud SQL with a private IP only; apps reach it through the Cloud SQL Auth Proxy with IAM login, without passwords.
- `container`: Postgres 18 with pg_cron and pgmq in a container on `iss-db`; `history` and `fetcher` log in with passwords. Traffic to `iss-db` stays inside the VPC but is not encrypted, the same as Redis and RabbitMQ. Cheaper, no Cloud SQL.

Switching from `cloudsql` to `container` deletes the Cloud SQL instance and its data; switching back leaves the old Postgres volume on `iss-db` (remove it by hand). Data is not copied; `./scripts/backfill-positions.sh 24` refills the last day.

`iss-db` exists only when `POSTGRES_BACKEND` is `container`, `QUEUE_BACKEND` is `rabbitmq` or `SESSION_BACKEND` is `redis`. With everything in Cloud SQL (`cloudsql`, `postgres`/`pgmq` queue, `postgres`/`hstore` sessions) Terraform does not create it, and switching to such a backend deletes it with its data on the next `./scripts/tf.sh apply`.

The UI VM has no external IP: cloudflared connects out to Cloudflare and talks to nginx over HTTPS with a Let's Encrypt certificate that certbot obtains through the Cloudflare DNS API.

Settings live in `config.json`; secrets live in Google Secret Manager. Terraform and the scripts run as the `terraform` service account with an exported key kept outside the project. Run every command from the repository root in WSL.

## 1. Tools (once per machine)

```bash
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates gnupg curl jq openssl
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y google-cloud-cli terraform python3-venv rsync shellcheck
```

Ansible itself is installed by the scripts into a venv in `~/.cache/iss-ansible` on first use.

Docker: Docker Desktop → Settings → Resources → WSL integration → enable the WSL distro. Check with `docker version`.

## 2. SSH key and login (once per machine)

```bash
ssh-keygen -t ed25519 -N '' -C iss-gcp -f ~/.ssh/iss_gcp_ed25519
install -d -m 700 ~/.ssh/iss_gcp
if ! grep -qxF 'Include iss_gcp/*.conf' ~/.ssh/config 2>/dev/null; then printf 'Include iss_gcp/*.conf\n\n%s\n' "$(cat ~/.ssh/config 2>/dev/null)" > ~/.ssh/config.new && mv ~/.ssh/config.new ~/.ssh/config && chmod 600 ~/.ssh/config; fi
gcloud auth login
```

## 3. Configuration

```bash
cp config.example.json config.json
```

Edit `config.json`:

- `project.id`: leave empty to let bootstrap create a new project, or put an existing project ID.
- `access.admin_cidrs`: your public IP with `/32` (`curl -s ifconfig.me`). SSH to the bastion is open only to these addresses.
- `access.ssh_port`: SSH port of the bastion (internal VMs stay on 22).
- `access.sa_key_file`: where the service account key is written, outside the project (default `../iss-gcp-keys/terraform.json`).
- `domain.zone`: your domain in Cloudflare; `domain.host`: the tunnel host name (`iss`, so the UI is `iss.<zone>`).
- `tls.email`: optional e-mail for Let's Encrypt; `tls.staging: true` uses the test CA while experimenting.
- `app.POSTGRES_BACKEND`: `cloudsql` or `container` (see above); `QUEUE_BACKEND` and `SESSION_BACKEND` choose RabbitMQ/Redis or Postgres.
- `postgres`: database name and the pgmq and pg_cron versions (pg_cron only matters in container mode).
- `cloudsql`: tier and Postgres version for Cloud SQL; the defaults are the smallest single-zone instance.
- `monitoring.ops_agent`: `true` installs the Google Cloud Ops Agent on every VM (metrics and logs to Cloud Monitoring/Logging) and lets Terraform create the dashboard, log-based metrics and alerts; `monitoring.notification_emails` lists the addresses that get the alerts, `monitoring.alerts` turns each alert on or off and sets its threshold and duration (see section 9).
- `vms`, `firewall`, `app` work as they are. Every app VM gets its own service account from Terraform, which can read only the secrets its `deploy/<key>/compose.yaml` references. `service_account: true` on a VM also gives it an IAM database user in Cloud SQL; with `cloudsql` `history` and `fetcher` need it.

`config.schema.json` describes every setting. Editors that understand JSON Schema show hints and errors when `config.json` starts with `"$schema": "./config.schema.json"` (as in the example). Every script, Terraform (through `tf.sh`) and Ansible check `config.json` against it before using it and stop with the validator's message, e.g. `$.app.QUEUE_BACKEND: 'kafka' is not one of …`. The first script run (usually `bootstrap.sh`) needs `python3` and `python3-venv` and creates the Python environment in `~/.cache/iss-ansible`: the validator and Ansible with its Galaxy collections, so it takes a minute or two and needs network access.

## 4. Bootstrap (once per project)

```bash
./scripts/bootstrap.sh
```

Creates or reuses the project, links billing (pass `--billing-account ID` if you have more than one open account), enables APIs, removes the `default` network, creates the state bucket, the `terraform` service account with the roles it needs (note: Service Account Admin applies to every service account in the project, including `terraform` itself, so keep its key private) and its key at `access.sa_key_file` and the secrets, and disables the default Compute Engine service account (the VMs' own service accounts are created by Terraform). Passwords are generated. Safe to run again. Rotate the key with `./scripts/sa-key-rotate.sh`.

Then set the two Cloudflare tokens (value is read from stdin):

```bash
./scripts/secret-set.sh CF_TUNNEL_TOKEN
./scripts/secret-set.sh CLOUDFLARE_API_TOKEN
```

- `CF_TUNNEL_TOKEN`: Zero Trust → Networks → Tunnels → your tunnel → the `eyJh…` part of the install command. The tunnel's public hostname `iss.<zone>` points to service `https://iss.<zone>:443` (type HTTPS, no TLS verification overrides: nginx answers under that name inside the compose network and cloudflared checks its certificate). Protect it with Cloudflare Access.
- `CLOUDFLARE_API_TOKEN`: My Profile → API Tokens → Create Token with permission `Zone → DNS → Edit` for your zone only. certbot uses it for the DNS-01 challenge.

## 5. Infrastructure

```bash
./scripts/tf.sh init
./scripts/tf.sh apply
rm -f ~/.ssh/iss_gcp/known_hosts
./scripts/tf.sh output -raw ssh_config > ~/.ssh/iss_gcp/hosts.conf
./scripts/ansible.sh site.yml
```

cloud-init only creates the users with their keys and a first sshd drop-in, so Ansible can log in. It runs once: after changing `admin_cidrs`, `ssh_port` or the key recreate the VM, e.g. `./scripts/tf.sh apply -replace='module.vm["jump"].google_compute_instance.this'`.

`site.yml` configures sshd, fail2ban (bastion), Docker with log rotation (app VMs), the guest agent and the Ops Agent (`platform.yml`), then deploys the app (`deploy.yml`, see section 6). It is safe to run again; a second run reports `changed=0` for the app VMs and `changed=2` for the bastion (adding and removing the temporary key). On the bastion it logs in as `iss-admin` with a metadata key that expires after 15 minutes and is removed at the end of the play; the guest agent then deletes the user, so between runs only `jump` exists there. `./scripts/ansible.sh` prints the `ansible-playbook` command it runs and passes extra arguments on, e.g. `--limit iss-db --check --diff`.

### Runbooks

```bash
./scripts/ansible.sh runbooks/app-compose.yml
./scripts/ansible.sh runbooks/os-update.yml
./scripts/ansible.sh runbooks/fail2ban-unban.yml -e ip=203.0.113.7
./scripts/ansible.sh runbooks/bastion-revoke.yml
```

- `app-compose.yml`: prints the `compose.yaml` and `secrets.list` every app VM would get (neither holds a secret value); runs only on your machine and changes nothing.

- `os-update.yml`: package upgrade on every VM, one at a time, rebooting only when Ubuntu asks for it; the bastion goes last. Rebooting `iss-db` or `iss-history` stops the app for a few minutes.
- `fail2ban-unban.yml`: unbans an address in the bastion's sshd jail. Your own address must be in `admin_cidrs`, which fail2ban never bans.
- `bastion-revoke.yml`: removes the temporary `iss-admin` key from the bastion if a run was interrupted (the key stops working after its expiry anyway).

### Existing stand with `.env` files on the VMs

```bash
./scripts/bootstrap.sh
./scripts/tf.sh apply
./scripts/ansible.sh deploy.yml
```

`bootstrap.sh` lets `terraform` grant `roles/secretmanager.secretAccessor`; `apply` gives each app VM read access to its own secrets (no VM restarts when every app VM already has a service account); `deploy.yml` installs `iss-run`, removes `/opt/iss/.env` and `/opt/iss/secrets`, and recreates only the containers whose configuration changed (the certbot containers on `iss-ui` once). If `apply` was skipped, the deploy stops with `secrets not readable on …` before it touches any container.

### Existing stand from before the Ops Agent

Add `"monitoring": {"ops_agent": true}` to `config.json`, then:

```bash
./scripts/bootstrap.sh
./scripts/tf.sh init
./scripts/tf.sh plan
./scripts/tf.sh apply
./scripts/ansible.sh site.yml
```

`bootstrap.sh` enables the Logging and Monitoring APIs and lets `terraform` grant the log and metric writer roles. `init` is needed for a new Terraform module. `plan` shows the moved IAM grants, a service account per VM, VMs updated in place (each stops and starts once to get its account) and a label on Cloud SQL; with a backend that does not need `iss-db` it also destroys `iss-db`. Then recreate the containers once (see `docs/monitoring.md`, step 1).

### Existing stand deployed with `deploy.sh`

```bash
./scripts/bootstrap.sh
./scripts/tf.sh plan
./scripts/tf.sh apply
./scripts/ansible.sh site.yml
```

First edit `config.json` like `config.example.json`: move `cloudsql.database_name` and `cloudsql.pgmq_version` into a new `postgres` section, add `postgres.pg_cron_version`, `app.POSTGRES_BACKEND: "cloudsql"` and `POSTGRES_PORT` in the firewall rules `history → db` and `fetcher → db`. Add `"$schema": "./config.schema.json"` at the top for editor hints. Every script checks the file first and names each key that is still wrong. `bootstrap.sh` creates the new `POSTGRES_HISTORY_PASSWORD` secret. `plan` must show only moved resources and nothing destroyed except `terraform_data.config_check` (a check without a real resource, now replaced by the schema).

### Existing stand created before Ansible

```bash
./scripts/tf.sh apply -replace='module.vm["jump"].google_compute_instance.this'
ssh-keygen -f ~/.ssh/iss_gcp/known_hosts -R "[<bastion IP>]:<ssh_port>"
./scripts/ansible.sh site.yml
```

The bastion needs the new cloud-init (its sshd must accept `iss-admin`); the other VMs only get labels in place. Docker and fail2ban installed earlier by cloud-init are kept.

Recovery without the bastion: `./scripts/tf.sh output -raw iap_ssh` prints the command, e.g. `gcloud compute ssh iss-db --project <id> --zone changeme --tunnel-through-iap`; for the bastion add `--ssh-flag=-p<ssh_port>`.

## 6. App

`site.yml` already deployed the app. To redeploy only the app, or one VM:

```bash
./scripts/ansible.sh deploy.yml
./scripts/ansible.sh deploy.yml --limit iss-history
./scripts/backfill-positions.sh 24
```

- `deploy.yml` renders and checks the `compose.yaml` of every VM before it changes any of them, then deploys `iss-db`, `iss-history`, `iss-fetcher`, `iss-ui` one by one. Images are built locally and copied to a VM only when they changed; a repeated run changes nothing.
- No VM holds a file with secret values. `/opt/iss/compose.yaml` has the non-secret values filled in and refers to secrets as `${NAME:?}`; `/opt/iss/secrets.list` names them. `iss-run` reads them from Secret Manager with the VM's service account and starts the command with them in its environment; `iss-compose` is `iss-run docker compose` for `/opt/iss`, and the systemd unit `iss.service` runs `iss-compose up -d` at boot. On a VM use `sudo iss-compose ps`, `sudo iss-compose logs history` and so on, not plain `docker compose`.
- Rotating a secret: `./scripts/secret-set.sh NAME`, then `sudo systemctl restart iss` on each VM that uses it (`/opt/iss/secrets.list` shows which). `REDIS_PASSWORD`, `CF_TUNNEL_TOKEN` and `CLOUDFLARE_API_TOKEN` take effect with that alone. RabbitMQ and the container-mode Postgres create their admin user only on an empty volume, so a new `RABBITMQ_USER`/`RABBITMQ_PASSWORD` also needs the user changed inside RabbitMQ, and a new `POSTGRES_PASSWORD` needs `deploy.yml` (which sets it).
- Postgres setup runs with the deploy through the `community.postgresql` modules: on `iss-history` for Cloud SQL (hstore, pgmq, pg_cron; a failed setup starts `history` again with the old schema and stops the run), on `iss-db` for container mode (roles `history`/`fetcher` with their passwords, extensions, pg_cron jobs).
- After changing `QUEUE_BACKEND` or `SESSION_BACKEND` run `deploy.yml`, unless the change creates or removes `iss-db`; after changing `POSTGRES_BACKEND`, or a change that creates or removes `iss-db`, run `./scripts/tf.sh apply`, then `site.yml`. Containers of the backend you turned off are removed.
- `backfill-positions.sh` loads past positions into Postgres through `iss-history` in either mode.
- `https://iss.<zone>`: the UI through Cloudflare Tunnel and Access.
- `./scripts/docker-stats.sh` shows containers, memory and disk of the app VMs.
- UI development: `cd services/ui && HISTORY_URL=http://localhost:8081 npm run dev` with `ssh -N -L 8081:127.0.0.1:8080 gcp-iss-history`.

## 7. Certificate inside the tunnel

nginx on `iss-ui` listens only on 443 inside the compose network, with a Let's Encrypt certificate for `iss.<zone>`. No port is published on the VM and the VM has no external IP; browsers see Cloudflare's certificate, the Let's Encrypt one secures the hop from cloudflared to nginx.

The certificate is backed up to the `LETSENCRYPT_STATE` secret after each deploy of `ui` when it changed (only the current host and its current certificate files, the two newest versions are kept) and restored after `destroy`/`apply`, so a new one is issued only on renewal. Let's Encrypt allows 5 identical certificates per week. The `certbot` container renews on its own and nginx reloads every 6 h; run `./scripts/ansible.sh deploy.yml --limit iss-ui` before `destroy` to save a renewed certificate. If certbot cannot issue a certificate, the deploy of `iss-ui` fails and nginx does not start; fix the cause (`sudo iss-compose logs certbot-init` on `iss-ui`) and deploy again.

## 8. Stop

Short break, data kept (disks, the bastion IP and Cloud SQL storage are still billed; leave out `iss-db` when it does not exist):

```bash
P=$(jq -r .project.id config.json)
gcloud compute instances stop iss-jump iss-db iss-history iss-fetcher iss-ui --project "$P" --zone changeme
gcloud sql instances patch "$(./scripts/tf.sh output -raw cloudsql_connection_name | cut -d: -f3)" --activation-policy=NEVER --project "$P"
```

The last command is only for `cloudsql`. Start again with `instances start` and `--activation-policy=ALWAYS`.

Long break, nothing billed except the state bucket and secrets (Postgres data is deleted in both modes):

```bash
./scripts/tf.sh destroy
rm -f ~/.ssh/iss_gcp/hosts.conf ~/.ssh/iss_gcp/known_hosts
```

## 9. Monitoring

With `monitoring.ops_agent: true` every VM sends CPU, memory, disk and syslog, and the app VMs send their container logs; nginx on `iss-ui` writes one JSON line per request. `./scripts/tf.sh apply` creates the log-based metrics, the email channels, the alerts and the dashboard `iss overview` (link: `./scripts/tf.sh output -raw monitoring_dashboard_url`); `destroy` deletes them. Settings, alert list, how to test an alert and the optional uptime check: [docs/monitoring.md](docs/monitoring.md). A stand whose monitoring was made by hand in the console needs the steps in section 9 there once.
