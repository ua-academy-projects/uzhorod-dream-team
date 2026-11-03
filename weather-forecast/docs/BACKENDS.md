# Selecting the queue and preferences backend

The backend is set by `app.backend` in the config. The deploy script passes it
to Fetcher and History as `WEATHER_BACKEND`.

| Value | Queue | Preferences | `broker` VM |
| --- | --- | --- | --- |
| `postgres` | PGMQ in Cloud SQL | hstore + TTL in Cloud SQL | not created |
| `rabbitmq_redis` | RabbitMQ | Redis | created; runs RabbitMQ and Redis |

The same Fetcher and History images support both modes. Cloud SQL is used in
both: it always stores weather records and job state, and the `pgmq` schema
exists in both modes.

## Secrets

Secrets are stored in Secret Manager (see the table in
[ARCHITECTURE.md](ARCHITECTURE.md#deployment)). Each password must contain at
least 16 characters from `A-Z a-z 0-9 . _ ~ -`, so it can be used in
connection URLs without escaping.

| Secret (`tf-weather-…`) | Needed in |
| --- | --- |
| `postgres-admin-password` | both modes (database maintenance) |
| `db-password` | both modes (History's `weather_app` role) |
| `fetcher-db-password` | `postgres` (Fetcher's `weather_fetcher` role) |
| `rabbitmq-password` | `rabbitmq_redis` (user `weather`, vhost `weather`) |
| `redis-password` | `rabbitmq_redis` |

A random value can be generated with `openssl rand -hex 24`.

The RabbitMQ and Redis addresses are not secrets: the deploy script builds
them from the VM addresses in the config (`app.services.<name>.host`).
Changing a password in Secret Manager and running the deploy again updates the
role or user and restarts only the containers that use it.

## RabbitMQ and Redis

- RabbitMQ (`app.services.rabbitmq.image`) runs with the volume
  `weather-rabbitmq` and the settings from
  `infra/deploy/templates/rabbitmq/rabbitmq.conf`. Its user and vhost are
  created on first start; the password is set on every deploy.
- Redis (`app.services.redis.image`) runs with the volume `weather-redis`. Its
  password is stored in `/etc/weather-forecast/redis.conf` (mode `600`), not
  in process arguments or the container environment.

Both images are pulled on the operator's machine and copied to `broker` like
the application images.

## Switching modes

Let active jobs finish, change `app.backend`, then apply Terraform and deploy
from the project root:

```bash
terraform -chdir=infra/terraform apply
infra/deploy/deploy.sh
```

Switching to `rabbitmq_redis` creates the `broker` VM; switching to
`postgres` destroys it together with the RabbitMQ and Redis volumes. Cloud SQL
keeps its data in both modes.

Pending messages and stored preferences are not transferred between backends.
An unfinished job from the previous mode can block a new collection until its
deadline expires. The same browser cookie can have different theme preferences
in each backend.

## Verification

In `rabbitmq_redis` mode check the containers on `broker`:

```bash
ssh gcp-tf-broker 'sudo docker ps --format "table {{.Names}}\t{{.Status}}"'
```

`weather-rabbitmq` and `weather-redis` must be running. In `postgres` mode
`gcloud compute instances list` shows no `broker` VM.

Start a collection through the public site:

```bash
curl -i -X POST https://app.weather-lab.pp.ua/api/collect
```

Use the returned `request_id` with `/api/jobs/<request_id>` and wait for
`completed`. Then check `/api/latest`, the hourly chart, and that the theme is
kept after reopening the page.

## Integration tests

Use a disposable PostgreSQL 18 database with PGMQ 1.13.0 and hstore enabled.
Set `TEST_DATABASE_URL` for the Go and Python test suites. The tests isolate
application tables in temporary schemas, but reset the two named PGMQ queues;
do not point them at a running application's database.
