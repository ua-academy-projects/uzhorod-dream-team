# kyiv_air.platform

Roles for the Kyiv air quality deployment. Settings come from the unified `deployment.json` (`DEPLOYMENT_CONFIG`); no Terraform outputs are needed.

| Role | Purpose |
|---|---|
| `common` | Shared config (`cfg`), derived values and SSH settings; a dependency of every other role |
| `base` | Docker, Google Cloud CLI, registry login, `kyiv-air` network |
| `secrets` | Reads Secret Manager values on the VM with its service account |
| `data_disk` | Formats and mounts the data disk |
| `container` | Generic container (one role for every service) |
| `postgres_local` | PostgreSQL on the DB VM when Cloud SQL is off |
| `redis` | Redis on the DB VM |
| `rabbitmq` | RabbitMQ on the DB VM |
| `migrate` | Runs database migrations |
| `certbot` | Certificates and renewal for the UI |
| `images` | Builds and pushes the application images from the local machine |
