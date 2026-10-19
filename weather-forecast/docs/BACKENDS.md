# Selecting the queue and preferences backend

`WEATHER_BACKEND` is read from the host's ignored
`var/deploy/secrets.env`. It is configuration, not a secret.

| Value | Queue | Preferences | Running DB VM containers |
| --- | --- | --- | --- |
| `rabbitmq_redis` (default when omitted) | RabbitMQ | Redis | PostgreSQL, RabbitMQ, Redis |
| `postgres` | PGMQ | hstore + TTL | PostgreSQL |

Write the value without quotes. Editing the host file does not change existing
containers: provisioning recreates them with the selected environment.
The same Fetcher and History images support both modes.

## Secrets

Keep the existing `WEATHER_DB_PASSWORD`, `RABBITMQ_URL`, and `REDIS_PASSWORD`
entries so the default mode remains available. PostgreSQL mode also needs
`WEATHER_FETCHER_DB_PASSWORD`: a separate password with 48 lowercase hexadecimal
characters. If this key does not exist yet, run this once from the project root
on the host to append a random value without displaying it:

```bash
printf '\nWEATHER_FETCHER_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)" >> var/deploy/secrets.env
chmod 600 var/deploy/secrets.env
```

Add or update one selector line in the same file:

```dotenv
WEATHER_BACKEND=postgres
```

Vagrant passes the selector as provisioning environment and transfers filtered
secret files over SSH. In PostgreSQL mode the secret distribution is:

| VM | Values transferred from the host |
| --- | --- |
| `db` | `WEATHER_DB_PASSWORD`, `WEATHER_FETCHER_DB_PASSWORD` |
| `history` | `WEATHER_DB_PASSWORD` |
| `fetcher` | `WEATHER_FETCHER_DB_PASSWORD` |
| `ui`, `bastion` | No service credentials |

On History, provisioning builds `DATABASE_URL` for `weather_app`; on Fetcher,
it builds a separate URL for `weather_fetcher`. Root-only files under
`/etc/weather-forecast/` supply these values to `docker run --env-file`.
They are not baked into images. PostgreSQL mode does not pass RabbitMQ or
Redis credentials to the application containers.

`weather_fetcher` can consume PGMQ `weather_requests` and publish to
`weather_responses`, with network login restricted to the Fetcher VM. The DB container also permits loopback
authentication for provisioning checks. It cannot access weather records,
job state, or preferences. Existing role passwords are not automatically
rotated by changing the host file; keep their current values.

The `postgres` mode uses two persistent PGMQ queues, `weather_requests` and
`weather_responses`. The database image includes the versioned PGMQ extension;
provisioning enables it with `CREATE EXTENSION pgmq`. The standard `hstore`
extension stores theme preferences as key/value pairs in `weather_preferences`.
`expires_at` provides the 30-day TTL; hstore itself does not expire entries.
Provisioning converts existing JSONB preferences to hstore without resetting
sessions or expiry times. Both extensions are available in either backend mode,
so switching does not require a different PostgreSQL image.

## First deployment of this implementation

For new VMs, `vagrant up` provisions the selected mode and builds the service
images. For existing VMs, run the following on the host from `infra/vagrant/`, after
preparing the configuration above and letting active jobs finish:

```bash
vagrant ssh history -c 'sudo docker stop --time 60 weather-history'
vagrant ssh fetcher -c 'sudo docker stop --time 60 weather-fetcher'
vagrant rsync
vagrant provision db
vagrant provision fetcher
vagrant provision history
```

The stop commands pause schedulers and workers during the transition. Rsync
copies the current migrations and application code to the existing VMs.
DB provisioning builds `weather-postgres:dev`, enables PGMQ 1.13.0 and hstore,
and applies migrations and grants before the new workers start.
Run these steps sequentially. The first deployment must build the updated
images; do not skip the build yet.

## Switching modes with existing images

Let active jobs finish, stop History and Fetcher as above, and change
`WEATHER_BACKEND` in the host file. Then, from `infra/vagrant/`, run:

```bash
WEATHER_SKIP_BUILD=1 vagrant provision db
WEATHER_SKIP_BUILD=1 vagrant provision fetcher
WEATHER_SKIP_BUILD=1 vagrant provision history
```

`WEATHER_SKIP_BUILD=1` requires existing local images and recreates
containers without building. Omit this flag when deploying changed source
code; sync the source with `vagrant rsync` before building. The flag also applies
to PostgreSQL and UI image provisioning, although switching backends does not require UI changes.

In PostgreSQL mode, DB provisioning stops existing RabbitMQ/Redis containers
and preserves their volumes. Switching back recreates and starts them using
those volumes. PostgreSQL data remains in its volume in both modes.

Pending messages and cached preferences are not transferred between backends.
An old unfinished job can block a new collection until its deadline expires.
The same browser cookie can have independent theme preferences in each backend.
PGMQ queues and hstore preference tables are included in the existing database
backup and restore; their original deadlines and expiry timestamps remain valid.

## Verification

From the host, check the active DB containers and the site:

```bash
vagrant ssh db -c 'sudo docker ps --format "table {{.Names}}\t{{.Status}}"'
curl -i -X POST http://127.0.0.1:8080/api/collect
```

Use the returned `request_id` with `/api/jobs/<request_id>` and wait for
`completed`. Check `/api/latest`, the hourly chart, and the saved theme after
reopening the page. In PostgreSQL mode only PostgreSQL should be running on DB;
RabbitMQ/Redis can still appear as stopped containers in `docker ps -a`.

To confirm application images were reused, compare their IDs before and after
the switch with `sudo docker image inspect weather-fetcher:dev --format '{{.Id}}'`
on Fetcher and the equivalent command for `weather-history:dev` on History.


## Integration tests

Use a disposable PostgreSQL 18 database with PGMQ 1.13.0 and hstore enabled.
Set `TEST_DATABASE_URL` for the Go and Python test suites. The tests isolate
application tables in temporary schemas, but reset the two named PGMQ queues;
do not point them at a running application's database.
