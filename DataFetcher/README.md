# DataFetcher

This directory contains the price collection applications and web UI, PostgreSQL initialization SQL, and the Docker Compose configuration.

## Services

| Service | Implementation | Role |
| --- | --- | --- |
| `fetcher` | Go | Polls price sources, serves the latest values, and processes collection tasks |
| `history` | Go | Periodically requests Fetcher, stores records, and provides an HTTP API |
| `ui` | FastAPI | Displays data and charts and stores user preferences |
| `postgres` | PostgreSQL 16 | Stores history, tasks, and preferences; provides PGMQ and HSTORE as needed |
| `rabbitmq`, `redis` | RabbitMQ, Redis | Request broker and preference cache for `hybrid` mode |

## Backend modes

`APP_BACKEND` must be the same for all three applications.

| Mode | Queue between History and Fetcher | UI preferences | Required services |
| --- | --- | --- | --- |
| `hybrid` | RabbitMQ; a PostgreSQL queue is available as a Fetcher fallback | PostgreSQL is the source of truth; Redis is the cache | PostgreSQL, RabbitMQ, Redis |
| `postgres` | PGMQ in PostgreSQL | HSTORE in PostgreSQL | PostgreSQL |

In `postgres` mode, the applications do not connect to RabbitMQ or Redis. See the [backend modes guide](../docs/BROKER_MODE.md) for details.

## Docker Compose

You need Docker Compose. Create a local configuration from the template and set your own passwords:

```powershell
Copy-Item .env.example .env
```

Set `APP_BACKEND=hybrid` or `APP_BACKEND=postgres`, validate the configuration, and start the services:

```sh
docker compose config
docker compose up --build -d
docker compose ps
docker compose logs -f ui history fetcher postgres
```

UI: [http://localhost:8000](http://localhost:8000). The History API is published on `http://localhost:8002`, and Fetcher on `http://localhost:8001`.

Stop the services while keeping volumes with `docker compose down`. The command `docker compose down -v` also deletes PostgreSQL, Redis, and RabbitMQ data.

The PostgreSQL image `ghcr.io/pgmq/pg16-pgmq:v1.10.0` includes the PGMQ files. `CREATE EXTENSION pgmq` registers the extension in a database; it does not install the extension files. The image also provides HSTORE.

## Vagrant

From the repository root, copy the Vagrant configuration template:

```powershell
Copy-Item DataFetcher\env_vagrant_example DataFetcher\.env
```

Set your passwords and configure the network bridge in the root `Vagrantfile`, then run `vagrant up`. The deployment creates five VMs; PostgreSQL, RabbitMQ, and Redis run together on the `postgres` VM. After changing `.env`, reprovision the VMs whose containers need the updated values:

```sh
vagrant provision postgres
vagrant provision fetcher
vagrant provision history
vagrant provision ui
```

See the [Vagrant guide](../docs/VAGRANT_BROKER_MODE.md) for detailed instructions.

## Configuration

Templates: [`.env.example`](.env.example) for Compose and [`env_vagrant_example`](env_vagrant_example) for Vagrant. Main variables:

- `APP_BACKEND` — `hybrid` or `postgres`.
- `SOURCES` — comma-separated `name=URL` pairs.
- `HISTORY_INTERVAL_SECONDS` — collection interval in seconds (10 seconds in the templates).
- `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` — History/UI connection settings.
- `FETCHER_POSTGRES_HOST`, `FETCHER_POSTGRES_PORT`, `FETCHER_POSTGRES_DB`, `FETCHER_POSTGRES_USER`, `FETCHER_POSTGRES_PASSWORD` — Fetcher's queue credentials.
- `RABBITMQ_URL`, `REDIS_URL` — used in `hybrid` mode.
- `HISTORY_SERVICE_URL` — History address used by UI; `COOKIE_SECURE` controls secure cookies for HTTPS.

Do not commit `.env`; it contains passwords.

## Health checks and database inspection

```sh
docker compose ps
docker compose logs --tail 100 postgres history fetcher
```

Check installed extensions with `SELECT extname FROM pg_extension WHERE extname IN ('pgmq', 'hstore');`. Check queues with `SELECT * FROM pgmq.list_queues();`. In `postgres` mode, completed tasks are in `fetcher_tasks`, active messages are in `pgmq.q_fetcher_tasks`, and price records are in `history`.

## Development

Run the Go service tests:

```sh
cd fetcher && go test ./...
cd ../history && go test ./...
```

Run UI tests (install packages from `ui/requirements-dev.txt` first):

```sh
cd ui
APP_BACKEND=postgres python -m pytest -q
```


## UI через Nginx і Cloudflare Tunnel (опціонально)

Для цього альтернативного режиму задайте `ip_https: false` та ім’я секрету
токена в UI startup, а також `tunnel_token_secret_id` у secret_manager.
Тоді на UI VM Terraform запускає Compose profiles `ui` і `tunnel`:
`Cloudflare HTTPS → cloudflared → http://nginx:80 → ui:8000`.
Nginx і UI публікують діагностичні порти лише на localhost VM
(8080 і 8000). Відкривати зовнішні порти 80/443 для тунелю не потрібно.

Перед запуском нової інфраструктури:

1. У Cloudflare створіть remotely-managed Cloudflare Tunnel.
2. Додайте published application route для свого домену з service URL
   `http://nginx:80` (контейнери працюють в одній Docker network).
3. Підготуйте GCP Secret Manager secret `datamonitor-cloudflare-tunnel-token`
   і додайте версію з токеном тунелю. Terraform описує контейнер секрету
   та IAM-доступ, але значення токена не зберігає. Якщо секрет створений
   вручну перед першим apply, імпортуйте його в Terraform:

   ```bash
   terraform -chdir=gcp-terra import \
     'module.secrets.google_secret_manager_secret.tunnel_token[0]' \
     projects/PROJECT_ID/secrets/datamonitor-cloudflare-tunnel-token
   ```

   Або спочатку створіть секрет через окремий підготовчий apply модуля:

   ```bash
   terraform -chdir=gcp-terra apply -target=module.secrets
   ```

   Після цього додайте версію через Google Cloud Console, а тоді виконайте
   звичайний plan/apply всієї конфігурації. Не передавайте токен у Git,
   config.json, startup metadata або аргументах команд.
4. Наявний секрет `datamonitor-env` також має містити робочий `.env`.

Ім'я секрету токена налаштовується у `secret_manager.tunnel_token_secret_id`
та `compute.instances.ui.startup.tunnel_token_secret_id`; вони мають збігатися.
Токен отримує лише UI startup script. Поточний service account спільний для
прикладних VM, тому IAM технічно дозволяє йому читати цей секрет на всіх цих VM.
На UI VM токен зберігається у файлі з правами 0400 і монтується лише в cloudflared.
Для HTTPS через тунель startup script виставляє `COOKIE_SECURE=true`.

Terraform вбудовує локальні Compose і Nginx конфігурації в startup script;
код застосунку, як і раніше, клонується з налаштованої у скрипті Git-гілки.
Заміна токена в Secret Manager застосовується після повторного запуску
startup script або перезапуску VM; автоматичного оновлення токена немає.

Для локального запуску лише UI і Nginx використовуйте profile `ui`.
Для тунелю додайте profile `tunnel` і `CLOUDFLARE_TUNNEL_TOKEN_FILE` — шлях
до локального файла токена. `NGINX_CONFIG_DIR` дозволяє перевизначити каталог
із Nginx конфігурацією.


## Поточний режим: HTTPS на статичній IP без домену

У `config.json` для UI встановлено `startup.ip_https: true`.
Cloudflare Tunnel у цьому режимі не запускається, токен не потрібний.
Terraform резервує статичну публічну IP та дозволяє TCP 80/443 лише для
VM із тегом `ui-service`. UI:8000 залишається прив'язаним до localhost.

Startup script на UI VM:

1. Запускає UI і Nginx з HTTP endpoint для ACME-перевірки.
2. Встановлює Certbot >= 5.4 у Python venv.
3. Отримує довірений IP-сертифікат Let's Encrypt через HTTP-01
   (`--ip-address`, профіль `shortlived`).
4. Вмикає Nginx HTTPS на 443 і редирект HTTP → HTTPS на фактичну IP VM.
   ACME challenge та локальна healthcheck-адреса залишаються доступними по HTTP.
5. Встановлює systemd timer `datamonitor-ip-https.timer`: перевірка сертифіката
   кожні шість годин, повторна спроба також у разі невдалої першої видачі.
   Після перевірки/поновлення Nginx перечитує сертифікат.

Сертифікати та ключі лежать у `/etc/letsencrypt` на boot-диску UI VM.
Вони переживають перезапуск VM; при видаленні boot-диска буде потрібна нова
видача. Для перевірки Let's Encrypt має досягати публічного порту 80;
поки VM зупинена, поновлення не працює. IP-сертифікат діє близько шести днів.
Certbot реєструє ACME-акаунт без email; значення email у конфігу не потрібне.

Перевірка після розгортання:

```bash
terraform -chdir=gcp-terra output -raw ui_public_ip
```

На UI VM:

```bash
systemctl status datamonitor-ip-https.timer
journalctl -u datamonitor-ip-https.service --no-pager -n 50
docker logs datamonitor-nginx --tail 50
/opt/datamonitor-certbot/bin/certbot certificates
```

Відкрийте `http://UI_IP/`: очікується перенаправлення на `https://UI_IP/`.
Початкова видача сертифіката виконується у startup script;
`terraform apply` сам по собі не підтверджує, що вона вже завершилась.
