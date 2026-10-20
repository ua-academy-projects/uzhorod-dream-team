# Vagrant: setup and backend modes

Vagrant provisions five Ubuntu 22.04 VMs:

| VM | Private IP address | Purpose |
| --- | --- | --- |
| `postgres` | `192.168.56.13` | PostgreSQL, RabbitMQ, and Redis |
| `history` | `192.168.56.12` | History API and periodic collection |
| `fetcher` | `192.168.56.11` | Price retrieval and task processing |
| `ui` | `192.168.56.14` | Web interface; also connected to a public bridge |
| `bastion` | `192.168.56.10` | SSH access through forwarded localhost port 2225; also connected to a public bridge |

## Prerequisites and startup

You need Vagrant, VirtualBox, and a network adapter whose name is set as `BRIDGE` near the top of the root `Vagrantfile`. Create the local configuration and set your own credentials:

```powershell
Copy-Item DataFetcher\env_vagrant_example DataFetcher\.env
```

Make sure `.env` has matching PostgreSQL and Fetcher passwords. Run these commands from the repository root:

```sh
vagrant up
vagrant status
```

Stop the VMs with `vagrant halt` and start them again with `vagrant up`. Containers use the `unless-stopped` restart policy and Docker starts them when the VM boots.

Check PostgreSQL with:

```sh
vagrant ssh postgres -c 'sudo docker exec postgres pg_isready -U postgres -d history'
vagrant ssh postgres -c 'sudo docker ps'
```

UI listens on port 8000 in the `ui` VM; its address depends on the public network adapter. Find the address with `vagrant ssh ui -c 'ip -4 addr'`.

## Configuration and reprovisioning

All VMs mount `DataFetcher/.env` at `/project/.env`. After changing values, reprovision the services whose containers need the updated environment:

```sh
vagrant provision postgres
vagrant provision fetcher
vagrant provision history
vagrant provision ui
```

For example, after changing `HISTORY_INTERVAL_SECONDS`, run only `vagrant provision history`. Changing `APP_BACKEND` requires reprovisioning Fetcher, History, and UI. Changes to PostgreSQL or broker configuration require `vagrant provision postgres`.

`HISTORY_INTERVAL_SECONDS` sets the collection interval; the example configuration uses 10 seconds. History makes its first request immediately after startup, then repeats at the configured interval.

## Choose a backend mode

Set `APP_BACKEND=hybrid` or `APP_BACKEND=postgres` in `DataFetcher/.env`, then reprovision the three application VMs.

- `hybrid`: RabbitMQ carries requests between History and Fetcher; Redis caches UI preferences; PostgreSQL stores history and preferences.
- `postgres`: PGMQ carries Fetcher tasks, and HSTORE stores preferences. Applications do not use RabbitMQ or Redis, although their containers may remain running.

See the [backend modes guide](BROKER_MODE.md) for details.

## Migrating an existing database to PGMQ

An existing PostgreSQL data directory cannot safely be opened by a different image just because both images use the same major PostgreSQL release. The PGMQ image `ghcr.io/pgmq/pg16-pgmq:v1.10.0` includes the required server extension files. The provisioner retains the previous container and volume, creates and verifies a backup, then initializes a separate volume for the new active database with PGMQ and the `fetcher_tasks` queue.

The new active database starts empty: the backup is verified but old rows are not restored into it. The old container and volume are retained for rollback. Do not run `vagrant destroy` or delete the volumes if you need to preserve the rollback option.

Switching only `APP_BACKEND` does not require switching the database image again. Provision PostgreSQL for initial PGMQ setup or when changing the database configuration.

## Logs and troubleshooting

```sh
vagrant status
vagrant ssh postgres -c 'sudo docker ps -a'
vagrant ssh postgres -c 'sudo docker logs --tail 100 postgres'
vagrant ssh fetcher -c 'sudo docker logs --tail 100 fetcher-service'
vagrant ssh history -c 'sudo docker logs --tail 100 history-service'
vagrant ssh ui -c 'sudo docker logs --tail 100 ui-service'
```

If PostgreSQL is available but no new records appear, check the collection interval and History/Fetcher logs. If containers do not pick up changes to `.env`, run `vagrant provision <vm>` for the affected VM.
