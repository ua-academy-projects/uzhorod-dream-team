# crypto-price-service on GCP

The same topology as the Vagrant setup, built by Terraform: two VPCs, a bastion,
four service VMs running prebuilt images, Cloud NAT, secrets in Secret Manager,
HTTPS on a custom domain.

```
git commit ─▶ ../build.sh ─▶ Cloud Build ─▶ Artifact Registry <image>:<commit>
terraform apply (image_tag) ─▶ VMs pull and run the images

https://<domain> ─▶ load balancer (Google-managed cert) ─▶ ui :5173 ─▶ history :3001 ─▶ db :5432 ◀─ fetcher
admin            ─▶ bastion :22022 (user jump) ─▶ :22 of db, fetcher, history, ui
```

## Usage

```bash
gcloud auth application-default login
read -rsp 'Cloudflare API token: ' CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN
cp backend.hcl.example backend.hcl && cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl

terraform apply            # 1. network, registry, secrets, bastion, HTTPS
../build.sh                # 2. images of the current commit; prints the tag
# 3. set image_tag in terraform.tfvars
terraform apply            # 4. the service VMs
```

A new version is a commit, `../build.sh` and a new `image_tag`; a rollback is the
previous tag. Postgres data live on the `crypto-db-data` disk and survive the db VM.

The VMs provision themselves on first boot: log with
`sudo journalctl -u google-startup-scripts.service`. The certificate becomes
`ACTIVE` 15–60 minutes after the first apply: `terraform output certificate_check`.

`terraform output -raw ssh_config > ~/.ssh/config.d/crypto-gcp` makes
`ssh gcp-db` go through the bastion.

## Inputs

| Name | Default | Description |
|---|---|---|
| `project_id` | — | GCP project |
| `console_user` | — | user of the Console SSH button |
| `ssh_source_ranges` | — | who may reach the bastion |
| `bastion_ssh_port` | `22022` | public SSH port of the bastion; 22 is for IAP only |
| `domain` | — | HTTPS name of the app |
| `cloudflare_zone_id` | — | Cloudflare zone holding the domain |
| `image_tag` | `null` | version to run; unset means no service VMs yet |
| `backend` | `postgres` | `redis` or `postgres` for the queue and sessions |
| `region`, `zone` | `europe-central2`, `-a` | location |
| `ssh_public_key_path` | `~/.ssh/crypto-gcp.pub` | key of jump and of the admin user |
| `admin_user` | `crypto` | admin account behind the bastion |

Credentials never live in the code: Google through Application Default Credentials,
Cloudflare through the `CLOUDFLARE_API_TOKEN` environment variable.

## Checks

```bash
terraform fmt -check -recursive && terraform validate
tflint --init && tflint
trivy config --skip-dirs .terraform .
```

Accepted exceptions are marked `#trivy:ignore` with the reason next to them.