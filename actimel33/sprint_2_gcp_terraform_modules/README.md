# crypto-price-service on GCP

## Requirements

`gcloud`, `terraform` 1.15+, `ansible-core` 2.19+, `docker`, `python3`, and `uv` for the pre-commit hook.
Ansible finds the VMs in GCP itself, so it needs the Python packages `google-auth` and `requests`;
[step 1](#1-tools-once-per-machine) installs them.

## Access

The project owner grants you the Owner role: Console → IAM & Admin → IAM → Grant access → your email → Basic → Owner.
The project is not in an organization, so Google sends you an invitation; you get access after you accept it.
Owner is full trust: it can read every secret and create keys for the `terraform` account.

## Step by step

Run the steps in order, in one terminal: later steps use the variables of step 3, the token that step 4 loads
and the SSH agent of step 7. Every command is one line. Step 1 is needed once per machine; after
`terraform destroy`, start again at step 4.

### 1. Tools, once per machine

From the repository root:

```bash
uv tool install pre-commit && pre-commit install
uv tool install --force ansible-core --with google-auth --with requests
gcloud auth login
```

### 2. Bootstrap

```bash
cd actimel33/sprint_2_gcp_terraform_modules
./bootstrap/bootstrap.sh
```

### 3. Shell variables

```bash
export PROJECT=$(python3 -c 'import json; print(json.load(open("../terraform_resources_configuration/config.json"))["project"]["id"])')
export ZONE=$(python3 -c 'import json; print(json.load(open("../terraform_resources_configuration/config.json"))["vms"]["defaults"]["zone"])')
export DOMAIN=$(python3 -c 'import json; print(json.load(open("../terraform_resources_configuration/config.json"))["load_balancer"]["domain"])')
echo "$PROJECT $ZONE $DOMAIN"
```

### 4. Terraform

```bash
cd terraform
source .env
terraform init -reconfigure -backend-config=backend.hcl
terraform plan
terraform apply
cd ..
```

### 5. Images

```bash
./build-and-push.sh
```

### 6. The key of the ansible account

```bash
rm -f ~/.config/gcloud/$PROJECT-ansible.json
(umask 077 && gcloud iam service-accounts keys create ~/.config/gcloud/$PROJECT-ansible.json --iam-account=ansible@$PROJECT.iam.gserviceaccount.com --project=$PROJECT)
```

### 7. SSH

```bash
gcloud compute ssh bastion --tunnel-through-iap --project=$PROJECT --zone=$ZONE --command=true
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/google_compute_engine
./ssh-config.sh
ssh-keygen -R bastion; for vm in $(gcloud compute instances list --project=$PROJECT --format='value(name)'); do ssh-keygen -R "$vm.$ZONE.c.$PROJECT.internal"; done
for vm in $(gcloud compute instances list --project=$PROJECT --format='value(name)'); do echo "$vm $(gcloud compute instances get-serial-port-output "$vm" --project=$PROJECT --zone=$ZONE 2>/dev/null | grep -A6 'BEGIN SSH HOST KEY FINGERPRINTS' | grep ED25519 | grep -oE 'SHA256:[A-Za-z0-9+/]+')"; done
for vm in $(gcloud compute instances list --project=$PROJECT --format='value(name)'); do ssh "$vm" true; done
```

### 8. Ansible

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
export GCP_SERVICE_ACCOUNT_FILE=~/.config/gcloud/$PROJECT-ansible.json
ansible-playbook site.yml
ansible-playbook site.yml
cd ..
```

### 9. Check the site

```bash
gcloud compute ssl-certificates list --project=$PROJECT --format='table(name,managed.status,managed.domainStatus)'
curl -s https://$DOMAIN/api/health
for vm in $(gcloud compute instances list --project=$PROJECT --filter='tags.items:internal-vm' --format='value(name)'); do echo "$vm $(ssh "$vm" systemctl is-active google-cloud-ops-agent)"; done
```


### 10. Tear down

```bash
cd terraform
source .env
terraform destroy
cd ..
```

`terraform destroy` deletes the VMs, the database with its data, the registry with its images, and the `sa-vm-*` and
`ansible` accounts with their keys. The project, the `terraform` account and the Cloudflare token stay. To bring
everything back, start again at step 4.

## How it works

- Terraform creates the VMs empty. Ansible installs Docker and the Ops Agent and starts the services on them; it
  connects through the SSH config from `ssh-config.sh` (see [SSH](#ssh)).
- The roles are in the collection `crypto.services` (`ansible/collections/ansible_collections/crypto/services`),
  and `site.yml` calls them as `crypto.services.<role>`. Ansible finds it next to `site.yml` by itself.
- Ansible needs no output of Terraform and has no inventory file:
  - every play that needs settings loads `config.json` with `vars_files`, and `site.yml` hands each role the
    values it uses in `vars:`;
  - `discover.yml`, the first play of `site.yml`, asks GCP for the running VMs of `project.id` and adds them to
    the inventory with `add_host`: the VMs with the network tag `internal-vm` to the group `private`, the bastion
    to `management`. It also finds the Cloud SQL endpoint and writes the CA of the instance to
    `ansible/files/db-ca.pem` (git-ignored).

  `discover.yml` reads GCP with the key in `GCP_SERVICE_ACCOUNT_FILE`: the key of the `ansible` account
  ([step 6](#6-the-key-of-the-ansible-account)), which may only read the VMs and Cloud SQL (`service_accounts` in
  `config.json`).
- Run `site.yml` without `--limit`: the `localhost` play of `discover.yml` must run, or there are no VMs to
  configure and `db_host` stays unknown.
- The VMs exist in the inventory only while `site.yml` runs: `ansible-inventory --graph` and ad-hoc commands such
  as `ansible history -m ping` do not see them. Use `ssh <vm>` instead.

After pulling changes that need new APIs or roles, re-run `./bootstrap/bootstrap.sh` before `terraform apply`.
Cloud SQL is such a change: bootstrap enables its APIs and gives the `terraform` account `roles/cloudsql.admin`.
It also gives `roles/servicedirectory.editor`: Google registers the Private Service Connect endpoint in
Service Directory (namespace `goog-psc-default`), and the account that creates the endpoint needs that right.
The `ansible` account is such a change too: bootstrap gives the `terraform` account
`roles/resourcemanager.projectIamAdmin`, so Terraform can grant the roles in `service_accounts` of `config.json`.
That role has no condition: whoever holds the `terraform` key can grant any role on the project, Owner included.
Keep the key to yourself.

## SSH

[Step 7](#7-ssh) sets SSH up. After it, `ssh bastion`, `ssh history` and the other VM names work from any
terminal.

- The user name comes from the OS Login profile of your `gcloud` account.
- `~/.ssh/config` needs `Include config.d/*` at the top; the script reminds you if it is missing.
- The bastion is reached through IAP (Identity-Aware Proxy), the other VMs through the bastion by their internal
  DNS names, so the config stays valid when VMs are recreated.
- A recreated VM has a new host key. `~/.ssh/known_hosts` keeps the bastion under the name `bastion` and the other
  VMs under their internal DNS names; step 7 removes both kinds.

## Logs and metrics

The role `ops_agent` installs Google Cloud Ops Agent on the private VMs with Google's script
(`add-google-cloud-ops-agent-repo.sh --also-install`). The agent sends the system logs (`/var/log/syslog`) to Cloud
Logging and the VM metrics to Cloud Monitoring: Console → Logging → Logs Explorer, and Console → Monitoring →
Metrics explorer, resource VM Instance.

- The VM accounts may write there with `roles/logging.logWriter` and `roles/monitoring.metricWriter`
  (`vms.service_account_roles` in `config.json`). Without these roles the agent runs, but every write is refused.
- The bastion has no agent: its subnet has neither Cloud NAT nor Private Google Access, so it can download nothing
  and reach no Google API.
- When the agent is already installed, the script prints `No changes made.`, and the task reports no change.

## Monitoring

The `monitoring` module (`terraform/modules/monitoring`) creates, from `monitoring` in `config.json`:

- the dashboard `crypto-price-service` (Console → Monitoring → Dashboards): requests to the load balancer by
  response class, CPU of every VM, memory and disk of the private VMs, and with `app.database = cloud_sql` CPU,
  memory, connections and disk of Cloud SQL. The CPU and memory charts draw the alert thresholds;
- an uptime check of `https://<load_balancer.domain><uptime_check_path>` every minute from `uptime_check_regions`;
  the answer must contain `uptime_check_content`;
- four alert policies, each sent by email to `notification_email`:

| Alert | Fires when |
|---|---|
| Site … is down | the health check fails in more than one region for 2 minutes |
| High CPU on a VM | the CPU of a VM stays above `cpu_threshold` for 5 minutes |
| Low memory on a VM | the used memory of a VM stays above `memory_threshold_percent` for 5 minutes |
| 5xx errors on the load balancer | more than `lb_5xx_ratio_threshold` of the requests get 5xx within 5 minutes |

- The `terraform` account needs `roles/monitoring.editor`: run `./bootstrap/bootstrap.sh` again before the first
  `terraform apply` with this module.
- The email of an alert lists what to check first. An incident closes by itself when its problem is gone, or after
  30 minutes without data.
- Right after the first `terraform apply` in a new project the site alert fires until Google issues the certificate
  (15–60 minutes): the uptime check validates it.
- The memory alert and the memory and disk charts come from the Ops Agent, so the bastion is not on them.
- With little traffic, one failed request is enough for the 5xx alert.
- Dashboards are free, Google does not charge for alert policies before September 2027, and the uptime check runs
  about 130,000 times a month, under the free million.

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
- The `service_accounts` module creates every service account but `terraform`: one per VM (`sa-vm-<VM>`) and the
  ones in `service_accounts` of `config.json`, each with its roles on the project.

## Leaving the project

You delete your keys, so they no longer work:

```bash
gcloud iam service-accounts keys delete <private_key_id from your key file> --iam-account=terraform@<project id>.iam.gserviceaccount.com --project=<project id>
rm ~/.config/gcloud/<project id>-terraform.json
gcloud iam service-accounts keys delete <private_key_id from your ansible key file> --iam-account=ansible@<project id>.iam.gserviceaccount.com --project=<project id>
rm ~/.config/gcloud/<project id>-ansible.json
```

The project owner then:

- removes your role: `gcloud projects remove-iam-policy-binding <project id> --member=user:<your email> --role=roles/owner`;
- lists the keys of the `terraform` account and deletes any key nobody claims:
  `gcloud iam service-accounts keys list --iam-account=terraform@<project id>.iam.gserviceaccount.com --managed-by=user`;
- creates a new Cloudflare token, stores it with `gcloud secrets versions add`, and revokes the old one in Cloudflare.
