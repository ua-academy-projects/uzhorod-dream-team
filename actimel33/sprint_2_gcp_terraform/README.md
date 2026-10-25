# Crypto Price Service — sprint 2: GCP with Terraform

Bitcoin price and its 7-day history. Three services talk only through a queue;
everything runs on Google Cloud, built by one `terraform apply`, served at
https://crypto.ai-optimizer.net.

```
https://crypto.ai-optimizer.net ─▶ load balancer (Google-managed cert) ─▶ ui :5173 (edge)
    ─▶ history :3001 ─▶ db :5432 ◀─ fetcher ─▶ CoinGecko (via Cloud NAT)
admin ─▶ bastion :22 (edge, user jump) ─▶ :22 of db, fetcher, history, ui (private)
```

| VM | Private IP | Edge IP | Runs |
|---|---|---|---|
| bastion | 192.168.77.5 | 192.168.78.5 | sshd only |
| db | 192.168.77.10 | — | Postgres + pgmq; Redis with `backend = "redis"`; log collector |
| fetcher | 192.168.77.11 | — | Go worker, CoinGecko |
| history | 192.168.77.12 | — | Node API, migrations, sessions |
| ui | 192.168.77.13 | 192.168.78.13 | nginx + React build |

## Layout

```
db/              Postgres image with pgmq, SQL migrations
services/        history (Node) and fetcher (Go)
ui/              React app served by nginx
logship/         log shipper (every VM) and collector (db)
cloudbuild.yaml  builds the four images
build.sh         builds the current commit in Cloud Build, pushes to Artifact Registry
terraform/       the whole deployment: networks, firewall, IAM, secrets, registry, VMs, HTTPS, DNS
```

Sprint 1 (Vagrant + libvirt) stays in [../crypto-price-service](../crypto-price-service).

## Deploy

Images are built once and pulled by the VMs; a version is a git commit.
See [terraform/README.md](terraform/README.md).
