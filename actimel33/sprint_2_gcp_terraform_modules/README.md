# crypto-price-service on GCP

Terraform modules for the crypto-price-service: five VMs (bastion, db, fetcher, history, ui) in a private VPC,
an HTTPS load balancer in front of ui, and a Cloudflare DNS record for the domain.
Everything is described in [`../terraform_resources_configuration/config.json`](../terraform_resources_configuration/config.json).

## Layout

| Path | What it does |
|---|---|
| `bootstrap/bootstrap.sh` | Day-zero setup: project, billing, APIs, state bucket, the `terraform` service account and your JSON key, the secret for the Cloudflare token. Writes `terraform/backend.hcl` and `terraform/.env`. Safe to re-run. |
| `terraform/` | `main.tf` only calls modules; each module gets its own part of `config.json`. |
| `build-and-push.sh` | Builds the app images and pushes them to Artifact Registry with the tags from `config.json`. |
| `ssh-config.sh` | Writes your SSH config for the VMs. |
| `../terraform_resources_configuration/config.schema.json` | JSON Schema of `config.json`: editor hints and the pre-commit check. |

## Requirements

`gcloud`, `terraform` 1.15+, `docker`, `python3`, and `uv` for the pre-commit hook.

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
```

Without `source .env`, Terraform runs as you instead of the `terraform` service account.
The state lives in the bucket, so everyone works with the same state; the bucket lock stops two applies at once.
The HTTPS certificate becomes ACTIVE 15–60 minutes after the DNS record exists.

## SSH

The first time, log in once with `gcloud`. It creates `~/.ssh/google_compute_engine` and your OS Login user:

```bash
gcloud compute ssh bastion --tunnel-through-iap --project=<project id> --zone=<zone of bastion>
```

Then:

```bash
./ssh-config.sh
ssh bastion
ssh db
```

- The user name comes from the OS Login profile of your `gcloud` account.
- `~/.ssh/config` needs `Include config.d/*` at the top; the script reminds you if it is missing.
- The bastion is reached through IAP (Identity-Aware Proxy), the other VMs through the bastion by their internal
  DNS names, so the config stays valid when VMs are recreated.
- A recreated VM has a new host key. Remove the old one: `ssh-keygen -R <vm>.<zone>.c.<project id>.internal`.

## Changing the configuration

- Edit `config.json`. VS Code checks it against the schema as you type; the pre-commit hook checks it on commit.
- `vms.defaults` apply to every VM; a machine lists only what differs.
- A new `image_tag` or a switch of `app.backend` (`postgres` / `redis`) recreates the affected VMs.

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
