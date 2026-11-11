# Terraform для Data Monitor

Кореневий main.tf викликає функціональні модулі; providers/backend, inputs,
outputs та декларативні imports відокремлені за призначенням.

| Модуль | Відповідальність |
|---|---|
| network | VPC, subnet, router/NAT |
| firewall | доступи за тегами, з урахуванням database/backend |
| secrets | service accounts, Secret Manager resources та scoped IAM; без payloads |
| cloud-sql | private services access, SQL instance/database та Cloud SQL Client IAM |
| compute-instance | VM, public IP лише там, де потрібний, початковий bastion bootstrap |
| registry | Artifact Registry, immutable tags та scoped reader/writer |
| iap | API та instance-scoped доступ до SSH bastion |
| monitoring | dashboard, VM/SQL alerts, HTTPS uptime, email channel та metric writer IAM |

Спільне джерело налаштувань — ../config.json. Backend bucket/prefix передаються
через ігнорований bootstrap/backend.hcl, який генерує bootstrap із того самого конфіга.

## Планування

```bash
make validate
terraform -chdir=gcp-terra fmt -check -recursive
terraform -chdir=gcp-terra validate
terraform -chdir=gcp-terra plan -out=/tmp/datamonitor.tfplan
# Лише після перегляду plan та за доручення на застосування:
terraform -chdir=gcp-terra apply /tmp/datamonitor.tfplan
```

Ігнорований operators.auto.tfvars.json містить iap_members та image_publishers.
Використовуйте явні user:/group:/serviceAccount: identities. Порожній iap_members
блокує перехід на приватний bastion. SSH-ключ має вже бути дозволений; IAP не
замінює SSH-автентифікацію. Для API/import/IAM може знадобитися активний GCP
account; не розширюйте постійні права terraform-deployer для зручності.

## Cloud SQL та міграція на декларативне керування

Наявний datamonitor імпортується, а не створюється повторно. imports.tf описує
прийняття instance, application database, двох наявних private service ranges,
peering connection та API. Перенесення Registry/IAP/IAM у модулі вже виконане
в поточному remote state; окремого migrations.tf у поточному коді немає.
Якщо працюєте з іншим старим state, спершу узгодьте адреси ресурсів — не застосовуйте
plan, який пропонує перестворення наявних ресурсів.

- cloud_sql.managed=true означає, що Terraform володіє цим SQL instance незалежно
  від поточного application backend. Перехід застосунку на container не видаляє
  збережену Cloud SQL базу й не припиняє її оплату.
- cloud_sql.adopt_existing=true потрібний лише для першого прийняття наявних
  ресурсів. Після import його можна вимкнути. Для нового середовища він false:
  Terraform створює ресурси зі вказаних параметрів.
- У container-only середовищі cloud_sql можна не задавати або managed=false;
  нові SQL ресурси не створюються. Не вимикайте managed для вже імпортованого
  інстансу як спосіб його видалення: prevent_destroy зупинить руйнівний plan.
- Захищено instance, database та private service network. Для database використано
  prevent_destroy та ABANDON для нових БД; для імпортованих БД значення
  deletion_policy зберігається через вузький ignore_changes, оскільки provider 6.8
  намагається виконати непідтримуваний PostgreSQL PATCH навіть для цього state-only поля. Секретні SQL passwords/users не є ресурсами
  цього модуля; вони залишаються в Secret Manager та логіці ініціалізації History.
- Параметри диска, edition, flags і backup policy відображають наявну конфігурацію.
  Поточна backup policy вимкнена; цей рефакторинг не змінює її й не змінює tier.
- Go Connector уже реалізований у Fetcher/History та використовує private IP.
  Це бібліотека застосунку, а не окремий GCP ресурс для створення в UI.

Вибір database.provider та compute.application.app_backend визначає ресурси VM:

| База | Backend | postgres VM |
|---|---|---|
| container | hybrid | PostgreSQL, RabbitMQ, Redis |
| container | postgres | PostgreSQL |
| cloud_sql | hybrid | RabbitMQ, Redis |
| cloud_sql | postgres | VM не створюється |

Перехід на режим без наявної postgres VM може запропонувати її видалення разом
із boot disk. Перед таким окремим переходом збережіть потрібні локальні volumes
та перегляньте plan. Поточний рефакторинг не перемикає режим і не видаляє VM/диски.

## Доступи та firewall

Bastion приватний, SSH 56789 дозволений тільки з IAP 35.235.240.0/20. Від bastion
до application VM відкрито SSH 22. UI → History та History → Fetcher — TCP 8000;
application → RabbitMQ 5672 і UI → Redis 6379 лише в hybrid; Fetcher/History →
PostgreSQL 5432 лише в container. Internet → UI: 80/443. Broad internal allow немає.

Application startup scripts видалені. Bootstrap створює лише project/state/auth
передумови; Cloud SQL/network більше не створюються shell-скриптом. Bastion
зберігає мінімальний початковий SSH/bootstrap та marker передачі керування Ansible.
Звичайний деплой: make deploy; повні інструкції — ../ansible/README.md.

## Моніторинг

Модуль `monitoring` створює dashboard, HTTPS uptime check, email channel та
алерти VM/Cloud SQL. Параметри — `config.json → monitoring`; Ops Agent
встановлює Ansible на application VM. [Покрокова інструкція Console](MONITORING.md).
