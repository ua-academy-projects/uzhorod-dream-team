# infra: deploying to GCP

Terraform creates the infrastructure (network, VMs, Cloud SQL, firewall, monitoring); Ansible (`my-ansible/`) configures the VMs.
`config.json` is the single source of truth (`example-config.json` is a template without personal data). Ansible details: `my-ansible/README.md`.

## Requirements
`terraform`, `ansible` (>= 2.18), `gcloud` (logged in: `gcloud auth application-default login`), Rust with the `x86_64-unknown-linux-musl` target,
a Cloudflare API token (Zone:DNS:Edit) and a domain in Cloudflare.

## 1. One-time setup
```bash
cp example-config.json config.json               # set your project_id, domain, email, bucket
cp bootstrap/bootstrap.env.example bootstrap/bootstrap.env   # PROJECT_ID, BILLING_ACCOUNT, ORG_ID, REGION
./bootstrap/bootstrap.sh                         # project, state bucket, service account; writes backend.hcl
./keys.sh                                        # your key for OS Login (SSH)
```
Secrets are never committed (`terraform.env`, `terraform.tfvars`, `backend.hcl`, `bootstrap.env`, `my-ansible/.vault_pass`):
- `terraform.tfvars`: `history_pass`, `cloudflare_token`;
- `terraform.env`: `TF_VAR_*` and `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` (`source terraform.env`);
- `my-ansible/secrets/vault.yml`: copy from `vault.yml.example`, then `ansible-vault encrypt`. `vault_cloudsql_history_password` must equal `history_pass`.

## 2. Infrastructure
```bash
source terraform.env
terraform init -backend-config=backend.hcl
terraform plan && terraform apply
```
The alerts on `workload.googleapis.com/*` metrics (PostgreSQL, RabbitMQ, Redis) can only be created once those metrics exist, i.e. after step 4. Run `terraform apply` a second time then.

## 3. Artifacts
```bash
cargo build --release --target x86_64-unknown-linux-musl --manifest-path ../apps/fetcher/Cargo.toml
cargo build --release --target x86_64-unknown-linux-musl --manifest-path ../apps/history/Cargo.toml
./upload-artifacts.sh all                        # or fetcher | history | frontend
```

## 4. VM configuration (Ansible)
Run from `my-ansible/` (it holds `ansible.cfg` and `.vault_pass`):
```bash
cd my-ansible
V="-e @secrets/vault.yml"
CSQL=$(terraform -chdir=.. output -raw cloudsql_private_ip)    # must not be empty
ansible-playbook ian.main.site $V -e queue_env_database_host="$CSQL" -e frontend_certbot_staging=true   # first run
ansible-playbook ian.main.site $V -e queue_env_database_host="$CSQL"                                    # later; also swaps staging for a production certificate
```
Add `--ask-vault-pass` if there is no `.vault_pass`. Useful tags: `services`, `frontend`, `certs`, `querycache`, `database`, `monitoring`, `overpass`.

- **Backend** = `active_backend` in `config.json` (1: Cloud SQL + RabbitMQ + Redis; 2: Postgres on a VM + pgmq). `-e backend=N` overrides it for one run; `ian.main.switch_backend` switches the services.
- **Ops Agent** is installed on the VMs by an OS policy from Terraform (up to ~10 minutes after the VM starts); the `monitoring` tag stops with an explanation if it is missing.
- **Overpass (optional)** (`--tags overpass`): the first import of the Ukraine map takes hours. It is ready when `/var/lib/overpass/init_done` exists on `overpassapi`; then run `--tags services` so the fetcher picks up `OVERPASS_URLS`. `e2-medium` is advisable for the import (2 GB RAM may not be enough).

## 5. Verification
```bash
curl -I https://<your domain>                    # 200
curl "https://<your domain>/api/pois?lat=48.62&lon=22.29&radius=1000&type=pharmacy"
```
On the fetcher: `curl localhost:8080/healthz`, `journalctl -u fetcher -n 30`. On history: `curl localhost:8081/stats`.

## Troubleshooting
| Symptom | Cause |
|---|---|
| Cloudflare 521/522 | nginx is not installed (run `--tags frontend`), or the firewall does not admit Cloudflare: `services.frontend.public_from` must contain `CLOUDFLARE` |
| `terraform output` empty / state error | no network path to GCS, or `source terraform.env` was not run |
| fetcher crashes with `Connection refused` | RabbitMQ/Redis on `querycache` are not running: `--tags querycache` (backend 1) |
| fetcher answers 502 after 70+ s | Overpass is not imported yet and the public instances do not answer |
| `site` requires `queue_env_database_host` | for backend 1 the Cloud SQL IP is passed from outside (step 4) |
