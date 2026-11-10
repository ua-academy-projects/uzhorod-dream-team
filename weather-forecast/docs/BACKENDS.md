# Selecting the backend and the database

Two independent config settings describe the deployment:

- `app.backend` selects the queue and preferences store. Ansible
  passes it to Fetcher and History as `WEATHER_BACKEND`.
- `app.database` selects where PostgreSQL runs.

| `app.backend` | Queue | Preferences |
| --- | --- | --- |
| `postgres` | PGMQ in PostgreSQL | hstore + TTL in PostgreSQL |
| `rabbitmq_redis` | RabbitMQ | Redis |

| `app.backend` | `app.database` | PostgreSQL | `db` VM runs |
| --- | --- | --- | --- |
| `postgres` | `vm` | container on `db` | PostgreSQL |
| `rabbitmq_redis` | `vm` | container on `db` | PostgreSQL, RabbitMQ, Redis |
| `postgres` | `cloudsql` | Cloud SQL | not created |
| `rabbitmq_redis` | `cloudsql` | Cloud SQL | RabbitMQ, Redis |

The `db` VM is created when at least one setting in its `only_for` matches.
`app.services.<name>.host` sets the VM of each service.

The same Fetcher and History images support every combination. PostgreSQL is
used in all of them: it always stores weather records and job state, and the
`pgmq` schema always exists.

## Secrets

Secrets are stored in Secret Manager (see the table in
[ARCHITECTURE.md](ARCHITECTURE.md#deployment)). Each password must contain at
least 16 characters from `A-Z a-z 0-9 . _ ~ -`, so it can be used in
connection URLs without escaping.

| Secret (`tf-weather-…`) | Needed in |
| --- | --- |
| `postgres-admin-password` | `cloudsql` (database maintenance) |
| `db-password` | always (History's `weather_app` role) |
| `fetcher-db-password` | `postgres` (Fetcher's `weather_fetcher` role) |
| `rabbitmq-password` | `rabbitmq_redis` (user `weather`, vhost `weather`) |
| `redis-password` | `rabbitmq_redis` |

A random value can be generated with `openssl rand -hex 24`.

The RabbitMQ and Redis addresses are not secrets: Ansible builds them from the
addresses of the VMs in `app.services.<name>.host`. Changing a password in
Secret Manager and running the playbook again updates the role or user and
restarts only the containers that use it.

## RabbitMQ and Redis

- RabbitMQ (`app.services.rabbitmq.image`) runs with the volume
  `weather-rabbitmq` and the settings from
  `rabbitmq.conf.j2` of the `container` role. Its user and vhost are created
  on first start; the password is changed when it no longer matches.
- Redis (`app.services.redis.image`) runs with the volume `weather-redis`. Its
  password is stored in `/etc/weather-forecast/redis.conf` (mode `600`), not
  in process arguments or the container environment.

Both images are pulled on `db` from their registry.

## Switching modes

Let active jobs finish, change `app.backend` or `app.database`, then apply
Terraform, then run the playbook:

```bash
terraform -chdir=infra/terraform apply
cd infra/ansible && ansible-playbook oleksiy_lohoyda.weather.site
```

Terraform creates or destroys the `db` VM and Cloud SQL according to the table
above. Destroying either one deletes its data. When `db` stays, Ansible
removes the containers that are no longer used and keeps their volumes.
Data is not transferred between `vm` and `cloudsql`: the new database starts
empty.

The Cloud SQL instance name stays reserved for a while after deletion, so
switching back to `cloudsql` right away can fail.

Pending messages and stored preferences are not transferred between backends.
An unfinished job from the previous mode can block a new collection until its
deadline expires. The same browser cookie can have different theme preferences
in each backend.

## Verification

Check the containers on `db`:

```bash
ssh gcp-tf-db 'sudo docker ps --format "table {{.Names}}\t{{.Status}}"'
```

`weather-postgres` must be running in `vm` mode, `weather-rabbitmq` and
`weather-redis` in `rabbitmq_redis` mode. With `postgres` and `cloudsql`,
`gcloud compute instances list` shows no `db` VM.

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
