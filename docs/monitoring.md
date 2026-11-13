# Monitoring

With `monitoring.ops_agent: true` in `config.json`:

- Ansible installs the Ops Agent on every VM. It sends host metrics (CPU, memory, disk, network) and syslog from all VMs and the Docker container logs from the app VMs to Cloud Logging and Cloud Monitoring.
- Terraform (module `infra/modules/monitoring`) creates the log-based metrics, one email notification channel per address, the alert policies and the dashboard `<prefix> overview`. `./scripts/tf.sh destroy` deletes them with the stand (alerts first, so `agent missing` does not fire during a destroy).

Nothing below needs the console except section 1 (checks), section 6 (uptime check) and section 7 (log exclusions).

What the code sets up for the logs:

- Every VM gets the service account `<prefix>-<key>` with `roles/logging.logWriter` and `roles/monitoring.metricWriter` (Terraform `iam`).
- Docker writes container logs with the `json-file` driver, tag = container name (`iss-ui-1`, `iss-history-1`, …), rotated at 10 MB × 3 files.
- The agent reads `/var/lib/docker/containers/*/*-json.log` into the log `docker`. Each entry has `jsonPayload.log` (the line), `jsonPayload.stream` and `jsonPayload.attrs.tag` (container name); the entry time is the container's time. The Go services write text lines such as `time=… level=INFO msg="position stored" …` or `level=ERROR msg="queue publish failed" …` to stdout.
- On the `ui` VM, lines that are JSON are parsed again: nginx writes one JSON line per request, so these entries carry the fields at the top of `jsonPayload` instead of `jsonPayload.log`:

| Field | Type | Example |
|---|---|---|
| `jsonPayload.time` | string | `2026-11-08T17:50:26+00:00` |
| `jsonPayload.status` | string | `"502"` |
| `jsonPayload.upstream_status` | string, empty for static files | `"502"` |
| `jsonPayload.request_time` | number, seconds | `0.012` |
| `jsonPayload.upstream_response_time` | string, empty for static files | `"0.011"` |
| `jsonPayload.method` | string | `GET` |
| `jsonPayload.uri` | string, without the query string | `/api/history` |
| `jsonPayload.bytes` | number | `150` |

nginx is the reverse proxy for `/api` (to `history`), so `status` is what the browser got from the stand and `upstream_status` is what `history` answered; a `502`/`504` with an `upstream_status` means `history` was down or too slow. Requests that Cloudflare Access rejects never reach nginx and are not counted.

## 1. Check the agents

1. **Monitoring → VM Instances**: every VM of the stand shows the Ops Agent as installed and running (a few minutes after `site.yml`).
2. **Monitoring → Metrics explorer**: `agent.googleapis.com/memory/percent_used`, filter `state = used`, grouped by `metadata.system_labels.name` (the VM name; `instance_name` exists only on `compute.googleapis.com` metrics): one line per VM.
3. **Logging → Logs Explorer**:

   ```
   resource.type="gce_instance"
   log_id("docker")
   jsonPayload.attrs.tag=~"-ui-"
   jsonPayload.status:*
   ```

   Open the site once; one entry per request appears with the fields from the table above.

On a stand whose containers were created before Docker got the new log options, `jsonPayload.attrs.tag` is missing until the containers are recreated, once per app VM:

```bash
ssh gcp-iss-ui 'sudo iss-compose up -d --force-recreate'
```

(likewise `gcp-iss-db`, `gcp-iss-history`, `gcp-iss-fetcher`). A new stand needs nothing.

## 2. Settings

All in `monitoring` of `config.json`; change, then `./scripts/tf.sh apply`. `config.schema.json` checks the values.

| Key | Meaning |
|---|---|
| `notification_emails` | One email channel per address; every alert notifies all of them. `[]`: alerts open incidents in the console only. |
| `alerts.<key>.enabled` | Create the policy. |
| `alerts.<key>.threshold` | See the table below; absent for alerts without one. |
| `alerts.<key>.duration_s` | Seconds the condition must hold before an incident opens (multiple of 60, 0 fires at once). |

| Alert key | Fires when | Threshold | Default | Severity |
|---|---|---|---|---|
| `nginx_5xx_share` | share of 5xx responses over 5 min above threshold | fraction 0–1 | 0.05, 300 s | WARNING |
| `history_unreachable` | nginx answered 502 or 504 in the last 5 min | — | 0 s | CRITICAL |
| `positions_stalled` | history stored no position in the last 5 min | — | 600 s | CRITICAL |
| `app_errors` | error lines from all containers in 5 min above threshold | count | 5, 300 s | WARNING |
| `agent_missing` | a VM sends no Ops Agent uptime metric | — | 300 s | CRITICAL |
| `disk_percent` | a disk of a VM (snap `loop` devices excluded) above threshold | percent | 85, 300 s | WARNING |
| `memory_percent` | memory of a VM above threshold | percent | 90, 300 s | WARNING |
| `cloudsql_cpu` | Cloud SQL CPU utilization above threshold (mode `cloudsql`) | fraction 0–1 | 0.8, 300 s | WARNING |
| `cloudsql_disk` | Cloud SQL disk utilization above threshold (mode `cloudsql`) | fraction 0–1 | 0.85, 300 s | WARNING |

Each policy is named `<prefix> <title>`, carries the label `iss-prefix`, closes by itself 30 min after the condition clears, and its email has the subject `[<prefix>] <title>` and what to check. `positions_stalled` fires once on a new stand between `tf.sh apply` and the end of `deploy.yml` and closes by itself; `agent_missing` fires when a VM is stopped or deleted on purpose (for example `db` after a backend switch) and closes 30 min later. `agent_missing.duration_s` must be at least 120 (an API limit). The disk alert skips snap `loop` devices, which are always 100 % used.

## 3. Log-based metrics

All on `resource.type="gce_instance" log_id("docker")`; `container` is the container name without the `iss-` prefix and the number (`history`, `cloudsql-proxy`, …). A log-based metric counts only entries written after it exists.

| Metric | Kind | Filter | Labels |
|---|---|---|---|
| `iss_nginx_requests` | counter | `jsonPayload.attrs.tag=~"-ui-" jsonPayload.status:*` | `status`, `upstream_status`, `class` (first digit of `status`: `2`, `4`, `5`) |
| `iss_nginx_request_time` | distribution, seconds, 20 exponential buckets from 1 ms | same | `class` |
| `iss_positions` | counter | lines `position published` (fetcher) and `position stored` (history) | `event` (`published`/`stored`), `container` |
| `iss_container_errors` | counter | `level=ERROR` (Go), `ERROR:`/`FATAL:`/`PANIC:` (Postgres), `[error]`, `[crit]`, `[alert]`, `[emerg]` (nginx, RabbitMQ) | `container` |

In PromQL they are `logging_googleapis_com:user_<name>{monitored_resource="gce_instance"}`.

## 4. Dashboard

`./scripts/tf.sh output -raw monitoring_dashboard_url` prints the link to `<prefix> overview`. Rows:

1. Summary: requests per second and positions stored per minute (number with a spark line; positions turn red at 0), 5xx share now (gauge, red above `alerts.nginx_5xx_share.threshold`).
2. Site: requests per second by status class (2xx, 3xx, 4xx, 5xx), status share of the last hour (donut), response time distribution (heatmap), response time p50/p95.
3. App: positions per minute (`published` by fetcher, `stored` by history; the two lines should run together), error share by container over the last hour (donut), error lines per minute by container, open incidents of the stand's alerts.
4. VMs: table of the current root disk use per VM, then CPU, memory and root disk over time; memory and disk are grouped by the VM name, which the default legend shows (legend templates with `${metadata.…}` do not resolve after grouping). CPU is the share of the VM's own CPU allotment: shared-core types such as `e2-micro` (0.25 vCPU, bursting to 2) go above 100 % while they burst. Disk shows only the root file system (`sda1`); `/boot/efi` (`sda15`), `/boot` (`sda16`) and snap `loop` devices are left out. The `disk used` alert still watches every file system except `loop`, so a full `/boot` still sends an email.
5. Cloud SQL disk (gauge, red above `alerts.cloudsql_disk.threshold`), CPU, memory, connections (mode `cloudsql` only). Cloud SQL reports CPU, memory and disk as fractions from 0 to 1, so the dashboard sets `unitOverride` `10^2.%` to show them in percent; the alert thresholds stay fractions (`0.8` = 80 %).
6. nginx access log and error log panels.

Changes made in the console are overwritten by the next `tf.sh apply`; change `infra/modules/monitoring/modules/dashboard/main.tf` instead.

## 5. Testing an alert

- Error lines: set `alerts.app_errors.threshold` to `0` and `duration_s` to `0`, `./scripts/tf.sh apply`, then cause one error: stop RabbitMQ for a minute (`ssh gcp-iss-db 'sudo docker stop iss-rabbitmq-1'`, then `start`; fetcher and history log `level=ERROR` while it is gone). The email arrives within a few minutes; restore the values and `apply`.
- `history_unreachable`: `ssh gcp-iss-history 'sudo docker stop iss-history-1'`, open the site, wait for the email, then `sudo docker start iss-history-1`. `positions_stalled` follows after its `duration_s`.
- **Monitoring → Alerting** shows the incidents; they close by themselves once the condition clears.

## 6. Uptime check (optional, by hand)

The site is behind Cloudflare Access, so an uptime check needs a service token, a secret that must not enter Terraform state:

1. Cloudflare dashboard → **Zero Trust → Access → Service Auth → Create service token**, name `gcp-uptime`; copy the client ID and secret.
2. In the Access application of `iss.<zone>` add a policy with action **Service Auth** that includes this token.
3. **Monitoring → Uptime checks → Create uptime check**: protocol HTTPS, resource type URL, host `iss.<zone>`, path `/`, check frequency 5 min; **Custom headers** `CF-Access-Client-Id` and `CF-Access-Client-Secret` with the token values and **Encrypt custom headers** on; response must contain `<div id="app">`.
4. Create the alert the wizard offers and pick the `<prefix> <email>` channel.

The token lives only in Cloudflare and in the uptime check; it never goes into this project. The check and its alert are not deleted by `destroy`.

## 7. What leaves the VMs

Container output is stored in Cloud Logging of the project and readable by everyone with the Logs Viewer role there (by default project owners and viewers). The apps never log credentials, and nginx logs neither headers nor query strings, but third-party containers write what they write: RabbitMQ logs the name of its default user (`RABBITMQ_USER`, kept as a secret here) at first start, and Postgres logs the text of a failed statement. Keep project access narrow, or drop such lines with a Log Router exclusion on the `_Default` sink (**Logging → Log router**), for example `log_id("docker") jsonPayload.attrs.tag=~"-(rabbitmq|postgres)-"`; excluded lines are not counted by the log-based metrics either.

## 8. Cost and turning it off

- Cloud Logging ingestion has a free allotment per project per month (50 GiB at the time of writing); this stand writes far less. Ops Agent metrics and log-based metrics are chargeable Monitoring metrics with a free allotment per billing account; check the current Cloud Observability pricing page.
- Container logs are the biggest part. To send less, exclude logs on the `_Default` sink, e.g. `log_id("docker") jsonPayload.stream="stdout" -jsonPayload.attrs.tag=~"-ui-"` (this also stops `iss_positions`, so disable `positions_stalled` with it).
- To turn it all off: `"ops_agent": false`, `./scripts/tf.sh apply` (deletes the dashboard, alerts, channels and metrics, then the agent service accounts and grants; VMs without a Cloud SQL account restart without one), then `./scripts/ansible.sh site.yml` (removes the package and repository).

## 9. Moving a stand with monitoring made by hand

The console-made metrics, dashboard, alerts and channel are not in the Terraform state and survived `destroy`; the first `apply` would fail on the existing metric names. Once:

1. `./scripts/bootstrap.sh` (gives `terraform@` `roles/monitoring.editor` and `roles/logging.configWriter`).
2. Add `notification_emails` and `alerts` to `monitoring` in `config.json` (copy from `config.example.json`).
3. Delete the old resources: `gcloud logging metrics delete iss_nginx_requests --project <project.id>` (and `iss_nginx_request_time` if you made it); in the console the dashboard `ISS infrastructure`, the `ISS …` alert policies and the `ISS email` channel.
4. `./scripts/tf.sh init` (new module), `./scripts/tf.sh apply`, then `./scripts/tf.sh plan` should show no changes.
