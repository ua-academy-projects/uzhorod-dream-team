# Bootstrap

Bash-скрипт готує GCP для Terraform: створює відсутні project, service account
і bucket, вмикає API, надає права та зберігає JSON-ключ локально.
Повторний запуск використовує наявні ресурси й ключ.

Потрібні Bash, jq та gcloud. Запускайте з адміністративного Google-акаунта.
Локальна копія jq у `.tools/` підхоплюється скриптом автоматично та виключена з Git.

1. Заповніть секцію `bootstrap` на початку кореневого `config.json`.
   Спільні `project_id`, `region` і `zone` задаються на верхньому рівні.
   Для нового проєкту потрібен `bootstrap.billing_account_id`.
   `bootstrap.folder_id` / `bootstrap.organization_id` необов'язкові.
2. Виконайте з кореня репозиторію:

```bash
gcloud auth login
bash gcp-terra/bootstrap/bootstrap.sh
source gcp-terra/bootstrap/terraform.env.sh
cd gcp-terra
terraform init -backend-config=bootstrap/backend.hcl -migrate-state
```

Конфігурація bootstrap зберігається у спільному `config.json` і відстежується Git.
Паролі та вміст ключів у нього не додавайте. `.credentials/`, `terraform.env.sh`
і `backend.hcl` виключені з Git. Не комітьте ключ. `terraform init` перенесе наявний локальний
state у спільний GCS backend; підтвердіть перенесення, коли Terraform запитає.
Для інших робочих копій спочатку підготуйте доступ до ключа, потім виконайте
`terraform init -backend-config=bootstrap/backend.hcl` без `-migrate-state`.

Для іншого проєкту оновіть `project_id`, `region`, `zone` та параметри
`bootstrap` у тому самому `config.json` перед запуском bootstrap і Terraform.

## Вибір бази та бекенду

У кореневому `config.json` задайте незалежні параметри:

```json
"database": {
  "provider": "container",
  "name": "history"
}
```

`compute.application.app_backend` задає `hybrid` або `postgres`.

| database.provider | app_backend | Сервіси на postgres VM |
| --- | --- | --- |
| `container` | `hybrid` | PostgreSQL + RabbitMQ + Redis |
| `container` | `postgres` | PostgreSQL (PGMQ + HSTORE) |
| `cloud_sql` | `hybrid` | RabbitMQ + Redis; історія в Cloud SQL |
| `cloud_sql` | `postgres` | Без контейнерів БД; Cloud SQL для історії, PGMQ і HSTORE |

Налаштування з Terraform передаються всім application VM через
`/etc/datamonitor/deploy.env` і мають пріоритет над `APP_BACKEND`, хостами,
назвами баз та `INSTANCE_CONNECTION_NAME` із Secret Manager. У контейнерному
режимі connector вимкнений, адреса PostgreSQL береться з
`compute.instances.postgres.network_ip`. Спільне ім'я бази задає `database.name`.
Для чинних volume зміна імені чи облікових даних не перейменовує базу/користувача.

Для `cloud_sql` bootstrap вмикає API, готує private services access, перевіряє
інстанс і створює його та базу, якщо їх немає. Параметри створення беруться із
`cloud_sql` (`edition`, `tier`, `database_version`, `region`, `zone`, `public_ip`,
`deletion_protection`). Існуючий інстанс не змінюється: невідповідність стану,
версії, регіону або приватної мережі зупиняє bootstrap з помилкою.
Cloud SQL і private services access управляються bootstrap, а не Terraform.
У контейнерному режимі SQL API/ресурси не створюються; вже наявна Cloud SQL
залишається працювати й оплачуватися.

Якщо VPC ще не існує, bootstrap ініціалізує Terraform з підготовленим backend і
виконує цільовий apply лише `module.network`, використовуючи згенерований ключ.
Це потрібно для private IP Cloud SQL. Повний `terraform apply` виконайте після
bootstrap зі своїм `admin_ip_cidr`. Bootstrap не запускає application VM.

Для нового Cloud SQL окремо задайте пароль користувача бази відповідно до
`POSTGRES_USER` / `POSTGRES_PASSWORD` у Secret Manager. Для `postgres` бекенду
встановіть SQL-only PGMQ за інструкцією в
[DataFetcher README](../../DataFetcher/README.md#pgmq-sql-only-on-cloud-sql).
History створює схему та налаштовує `fetcher_worker`; запускайте його перед Fetcher.
Паролі не зберігаються в `config.json` чи Terraform state.

Після зміни перемикачів запустіть bootstrap (для Cloud SQL), потім
`terraform apply`: startup metadata оновляться. Для наявних VM після apply
потрібен перезапуск, щоб виконався startup script з новими налаштуваннями.
Спочатку перезапустіть postgres VM, потім History, Fetcher та UI.
Репозиторій/гілка в `compute.application` мають містити оновлені скрипти.
Перед ручним повторним запуском `start-service.sh` завантажте
`source /etc/datamonitor/deploy.env`; `deploy.sh` робить це автоматично.
Перемикання не переносить дані; локальний `postgres_data` зберігається при зупинці.

Перевірки без доступу до GCP або Docker:

```bash
terraform -chdir=gcp-terra validate
```

Команди Cloud SQL і private services access звірені з офіційною документацією:
[instances create](https://docs.cloud.google.com/sdk/gcloud/reference/sql/instances/create),
[VPC peering connect](https://docs.cloud.google.com/sdk/gcloud/reference/services/vpc-peerings/connect).
