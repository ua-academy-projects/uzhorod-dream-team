# crypto-price-service on GCP

## Requirements

`gcloud`, `terraform` 1.15+, `ansible-core` 2.19+, `docker`, `python3`, and `uv` for the pre-commit hook.

## Access

The project owner grants you the Owner role: Console → IAM & Admin → IAM → Grant access → your email → Basic → Owner.
The project is not in an organization, so Google sends you an invitation; you get access after you accept it.
Owner is full trust: it can read every secret and create keys for the `terraform` account.

## First-time setup

From the repository root:

```bash
uv tool install pre-commit && pre-commit install
gcloud auth login
cd actimel33/sprint_2_gcp_terraform_modules
./bootstrap/bootstrap.sh
```

- `project.id` is set in `config.json`: bootstrap reuses that project and creates your own key in `~/.config/gcloud/`.
- `project.id` is empty: bootstrap creates a new project and writes its ID to `config.json`. Commit that change.
- In a new project, add the Cloudflare API token once. Create it in Cloudflare (My Profile → API Tokens,
  permission Zone → DNS → Edit for the zone of the domain) or ask the project owner. Bootstrap prints the command
  to store it; the input is hidden.

`terraform/backend.hcl` and `terraform/.env` are personal and git-ignored. `.env` holds no secrets:
it points to your key and reads the token from Secret Manager each time you source it.
After `source .env` the token is in your shell environment, so do not share the output of `env`.

## Deploy

```bash
cd terraform
source .env
terraform init -reconfigure -backend-config=backend.hcl
terraform plan
terraform apply
cd .. && ./build-and-push.sh
./ssh-config.sh
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml
```

- Terraform creates the VMs empty. Ansible installs Docker and starts the services on them; it connects through
  the SSH config from `ssh-config.sh` (see [SSH](#ssh)).
- `terraform apply` writes the inventory `ansible/inventory/inventory.ini`. With `app.database = cloud_sql`,
  `terraform apply` also writes the CA of the database to `ansible/files/db-ca.pem`. Both are git-ignored:
  run `terraform apply` before Ansible.
- A second `ansible-playbook site.yml` run must show `changed=0`.

Without `source .env`, Terraform runs as you instead of the `terraform` service account.

Do not run Terraform with `TF_LOG=DEBUG` or `TF_LOG=TRACE`: the log then holds the requests to Google, passwords included.

After pulling changes that need new APIs or roles, re-run `./bootstrap/bootstrap.sh` before `terraform apply`.
Cloud SQL is such a change: bootstrap enables its APIs and gives the `terraform` account `roles/cloudsql.admin`.

## SSH

The first time in a project, log in once with `gcloud`. It creates `~/.ssh/google_compute_engine` if you have none
and your OS Login user for this project:

```bash
gcloud compute ssh bastion --tunnel-through-iap --project=<project id> --zone=<zone of bastion>
```

Then:

```bash
./ssh-config.sh
ssh bastion
ssh history
```

- The user name comes from the OS Login profile of your `gcloud` account.
- `~/.ssh/config` needs `Include config.d/*` at the top; the script reminds you if it is missing.
- The bastion is reached through IAP (Identity-Aware Proxy), the other VMs through the bastion by their internal
  DNS names, so the config stays valid when VMs are recreated.
- A recreated VM has a new host key. Remove the old one: `ssh-keygen -R <vm>.<zone>.c.<project id>.internal`.

## Database

`app.database` in `config.json` picks where Postgres runs:

- `cloud_sql`: Cloud SQL, see below.
- `vm`: Postgres 17 in Docker on the `db` VM, as before Cloud SQL. See [On the db VM](#on-the-db-vm).

To switch, change `app.database`, then run `terraform apply` and `ansible-playbook site.yml`.
Switching deletes the old database: the Cloud SQL instance, or the `db` VM with its data disk. The data is not
moved, so the new database starts empty.

### Cloud SQL

Postgres runs in Cloud SQL (`cloud_sql` in `config.json`). The `db-f1-micro` instance costs about 9–11 USD a month;
the Private Service Connect endpoint and the 10 GB disk are billed on top.

- The instance has no public IP. The only way in is a Private Service Connect endpoint: an internal IP in the
  `private` subnet.
- TLS is required. history and fetcher check the server certificate against the CA of the instance
  (`sslmode=verify-ca`); Ansible puts the CA in `/etc/crypto/db-ca.pem`.
- Terraform creates the user `app` with the password from the secret `crypto-db-app-password`. With the `postgres`
  backend, `crypto-db-roles.service` on the history VM creates `queue_worker` for the fetcher.
- `terraform destroy` deletes the instance with its data: there are no backups.
- The `db` image is not built any more; `db/Dockerfile` stays in the repository.

To change a database password, raise the `version` of its secret in `config.json` and run `terraform apply`.
The services read passwords only when they start, so restart them:

- `crypto-db-app-password` (Terraform sets it for `app`): `ssh history sudo systemctl restart crypto-history.service`.
- `crypto-db-queue-worker-password`: `ssh history sudo systemctl restart crypto-db-roles.service` sets it for
  `queue_worker`, then `ssh fetcher sudo systemctl restart crypto-fetcher.service`.

To open psql, look up the endpoint IP, then run psql on the history VM:

```bash
gcloud compute addresses describe crypto-db-psc --region=europe-central2 --project=<project id> --format='value(address)'
ssh history
PGPASSWORD=$(gcloud secrets versions access latest --secret=crypto-db-app-password) sudo --preserve-env=PGPASSWORD docker run --rm -it -e PGPASSWORD -v /etc/crypto/db-ca.pem:/certs/db-ca.pem:ro postgres:17-alpine@sha256:266d3c257594e195b309ae9d1805e54c788f1d7b375f56bf6c367aac6c917e7b psql "host=<endpoint IP> dbname=crypto user=app sslmode=verify-ca sslrootcert=/certs/db-ca.pem"
```

### On the db VM

- The `db` VM exists only with `app.database = vm` (`databases` in `vms.machines.db`). The `postgres` role
  formats its data disk `crypto-db-data-disk` once, mounts it at `/mnt/data` and runs `crypto-db.service`.
- The data disk keeps the data when the VM is recreated; `terraform destroy` deletes it.
- Only history and fetcher reach port 5432 (`firewall.vm`). They connect inside the private subnet without TLS.
- `app` is the superuser of this Postgres, as before Cloud SQL. Postgres sets its password from
  `crypto-db-app-password` only when the data disk is new, so a new version of that secret does not reach a
  database that already exists.
  `crypto-db-queue-worker-password` works as with Cloud SQL.

To open psql:

```bash
ssh db
sudo docker exec -it crypto_db psql -U app -d crypto
```

## Changing the configuration

- Edit `config.json`. VS Code checks it against the schema as you type; the pre-commit hook checks it on commit.
- `vms.defaults` apply to every VM; a machine lists only what differs.
- After a change, run `terraform apply`, then `ansible-playbook site.yml`: a new `image_tag`, a switch of
  `app.backend` (`postgres` / `redis`) or a switch of `app.database` (see [Database](#database)) reaches the VMs
  only through Ansible.
- A VM with `backends` exists only for those backends: `redis` creates the `broker` VM with Redis, `postgres` removes it.

## Leaving the project

You delete your key, so it no longer works:

```bash
gcloud iam service-accounts keys delete <private_key_id from your key file> --iam-account=terraform@<project id>.iam.gserviceaccount.com --project=<project id>
rm ~/.config/gcloud/<project id>-terraform.json
```

The project owner then:

- removes your role: `gcloud projects remove-iam-policy-binding <project id> --member=user:<your email> --role=roles/owner`;
- lists the keys of the `terraform` account and deletes any key nobody claims:
  `gcloud iam service-accounts keys list --iam-account=terraform@<project id>.iam.gserviceaccount.com --managed-by=user`;
- creates a new Cloudflare token, stores it with `gcloud secrets versions add`, and revokes the old one in Cloudflare.
