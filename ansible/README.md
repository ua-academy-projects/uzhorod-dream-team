# Ansible для GCP

## Звичайний запуск

Із кореня репозиторію:

```bash
make setup       # один раз на цій машині
make deploy      # повний деплой
make deploy-ui   # лише UI, без prepare
make inventory   # поточні запущені VM
```

`make deploy` запускає зупинені VM цього застосунку, збирає/публікує реліз
або повторно використовує його manifest, чекає SSH через IAP і виконує site.yaml.
Команда не створює VM і не запускає Terraform. `make deploy-ui` також запускає
наявні VM, але застосовує тільки роль UI; для початкового налаштування потрібен
повний deploy. Усі VM мають існувати після погодженого Terraform apply.

Перед новим релізом зробіть commit і push змін у DataFetcher. Manifest
зберігається в `.deploy/releases/<application-commit>.json` (локально, поза Git).
Зміни лише Ansible/Terraform не спричиняють повторної збірки застосунку.
Щоб застосувати попередній реліз: `make deploy RELEASE=/absolute/path/release.json`.
Make використовує окремий `.venv` та локальні collections; активувати venv вручну
не потрібно. Активна gcloud-сесія потрібна для IAP/start, ADC — для inventory/push.

`config.json` — спільні несекретні налаштування; `config.schema.json` — їхня схема.
Кожен playbook перевіряє конфіг на controller перед змінами VM, включно з
точковим запуском `--limit ui`. Cloud SQL залишається зовнішньою передумовою:
наявний Terraform не створює інстанс.

## Підготовка controller

Потрібні Ansible, Python із залежностями нижче, gcloud, Git, а для збірки —
Docker із доступом до daemon та можливістю збирати `linux/amd64`.

```bash
python3 -m pip install -r ansible/requirements-controller.txt
ansible-galaxy collection install -r ansible/requirements.yaml
ansible-playbook -i localhost, ansible/playbooks/validate.yaml
ansible-playbook -i ansible/inventory.yaml ansible/playbooks/site.yaml --syntax-check
```

Використовуйте venv, якщо системний Python забороняє pip install. Python, яким
виконується локальний validate, також має містити jsonschema; за потреби задайте
`-e ansible_python_interpreter=/absolute/path/to/venv/bin/python` для localhost.

## Перший перехід на Artifact Registry та IAP

Для нового середовища або першого переходу підготуйте й перегляньте Terraform
plan з `iap_members` та, за потреби, `image_publishers` (див. `gcp-terra/README.md`).
Без явного `iap_members` plan зупиниться до видалення публічного IP bastion.
Для нових API/IAM може знадобитися активний адміністратор; не розширюйте постійні
права terraform-deployer лише для цього переходу.

Після погодженого apply перевірте IAP SSH, створіть реліз і виконайте Ansible.
VM startup лишається вимкненим для застосунків; bootstrap SSH bastion збережено.
SSH-ключі повинні вже бути дозволені на VM: IAP не замінює SSH-автентифікацію.

## Збірка та immutable релізи

Збірка відокремлена від деплою. Commit і push змін у `DataFetcher/` обов'язкові:
VM отримують із Git SQL/Compose/nginx assets саме цього commit. Dockerfile
Fetcher/History тепер запускає процес під UID/GID 65532; UI вже використовує
користувача app. Змін у бізнес-логіці немає.

Налаштуйте ADC publisher (`gcloud auth application-default login` або наявні
ADC credentials). Йому потрібен Artifact Registry Writer на цьому repository.

```bash
ansible-playbook -i localhost, ansible/playbooks/build.yaml
# Результат: /tmp/datamonitor-release-<40-char-commit>.json
# Або власне місце збереження:
ansible-playbook -i localhost, ansible/playbooks/build.yaml \
  -e build_release_file=/tmp/datamonitor-release.json
```

Playbook збирає три образи, пушить теги commit SHA й записує manifest із
`app_release_commit` та `app_images` (`repository/service@sha256:...`). Registry
забороняє змінювати теги. Повторна збірка того самого commit не може підмінити
вже опублікований тег; для іншого вмісту потрібен новий commit.
Збережіть manifest як артефакт релізу поза `/tmp`. Він не містить секретів.
Налаштовуваний `build_source_dir` має вказувати на корінь цього репозиторію.

## Inventory та SSH

- `inventory.gcp.yaml` отримує RUNNING VM з GCP API. Потрібні ADC і
  `compute.instances.list`, наприклад Compute Viewer. Project, zone та п'ять
  імен VM у джерелі буквальні: оновлюйте їх разом із `config.json`.
- `inventory.yaml` — статичний варіант і syntax-check без GCP API.
- Обидва використовують `group_vars/all.yaml`: внутрішні адреси, SSH user і порт
  bastion із config, ключ `~/.ssh/google_compute_engine`, Python `/usr/bin/python3.12`.
- До bastion з'єднання йде через `gcloud compute start-iap-tunnel`, до application
  VM — через SSH forwarding на bastion, який також доступний через IAP.
  Локальний SSH config для ProxyJump не потрібний, host-key checking збережений.
- Оператору потрібні IAP Tunnel Resource Accessor на bastion і Compute read
  permissions. `gcloud auth login` для IAP та ADC для inventory — різні credentials.
- Не поєднуйте обидва inventory: вони називають ті самі VM по-різному.
  Група `ui` працює в обох; GCE hostname в динамічному inventory — `ui-instance`.

```bash
ansible-inventory -i ansible/inventory.gcp.yaml --graph
ansible-playbook -i ansible/inventory.gcp.yaml ansible/playbooks/site.yaml --list-hosts
# Лише коли потрібен деплой:
ansible-playbook -i ansible/inventory.gcp.yaml ansible/playbooks/site.yaml \
  -e @/tmp/datamonitor-release.json
ansible-playbook -i ansible/inventory.gcp.yaml ansible/playbooks/site.yaml \
  --limit ui -e @/tmp/datamonitor-release.json
# Лише оновлення UI без prepare:
ansible-playbook -i ansible/inventory.gcp.yaml ansible/playbooks/ui.yaml \
  -e @/tmp/datamonitor-release.json
```

Fetcher/History/UI вимагають повний manifest, перевіряють registry paths/digests,
автентифікуються metadata token власної VM й використовують `build: never`,
`pull: missing`. Кеш Docker повторно використовує той самий digest.
Для відкату передайте попередній manifest; це не відкочує схему чи дані БД.
Playbook збірки не імпортується в `site.yaml`.

## Ролі та порядок

`site.yaml`: wait → bastion → prepare → postgres → history → fetcher → ui.
`prepare.yaml`: common і docker лише для internal. Окремі playbook-и збережено.
`app_source` отримує Git-код без force; `compose_app` має окремі render/start/cleanup,
щоб PostgreSQL зупиняв зайві сервіси між render і start без видалення volumes.
Порожній список запуску Compose заборонений. PostgreSQL/RabbitMQ/Redis — готові
образи; у режимі cloud_sql + postgres запуск контейнерів на postgres VM пропускається.

Секрети читає `secret_access` через metadata/Secret Manager URI без gcloud на VM;
env належать root із `0600`, `no_log` і вимкненим diff. VM accounts отримують
лише свої секрети; Artifact Registry Reader потрібен тільки Fetcher/History/UI.
Старий спільний env видаляється після успішних перевірок сервісу.

Усі керовані Compose-сервіси мають json-file logs: 10 MiB × 3 файли.
Fetcher/History/UI: read-only rootfs, cap_drop ALL, no-new-privileges і обмежений
/tmp у tmpfs. Nginx: read-only rootfs, tmpfs для cache/run/tmp та no-new-privileges;
штатні capabilities залишені для старту root master, worker user і читання TLS key.
PostgreSQL/RabbitMQ/Redis зберігають writable volumes і штатних користувачів;
для них додано no-new-privileges, без небезпечного примусового cap_drop ALL.

HTTPS, Certbot і renewal timer залишаються в UI; prepare/deploy мають block/always
для відновлення timer навіть після помилки. У check mode секрети, login, запуск
контейнерів і cleanup пропускаються; на порожній VM checkout може бути відсутнім.
Порти Ansible, bind-адреси й `config.json` firewall повинні відповідати одне одному.
Локальний/Vagrant шлях `DataFetcher/docker-compose.yml` не змінено.
