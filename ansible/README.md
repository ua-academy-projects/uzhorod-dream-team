# Ansible для Data Monitor

Сценарії й налаштування конкретного застосунку відокремлені від бібліотеки
перевикористовуваних ролей:

```text
ansible.cfg                    # шляхи roles/collections та default inventory
config.json                    # параметри проєкту й SSH/IAP
ansible/
  playbooks/                   # site, release, build, start, configure, окремі VM
  roles/                       # логіка саме Data Monitor
    config/, validate/, inventory/, images/, registry_access/
    bastion/, postgres/, history/, fetcher/, ui/
  collections/ansible_collections/datamonitor/platform/
    galaxy.yml
    meta/runtime.yml
    roles/                     # загальні операції з явними параметрами
      common/, docker/, connection/, app_source/, compose_app/
      secret_access/, power/
  requirements.yaml
  requirements-controller.txt
```

Project playbook-и викликають локальні ролі за коротким ім'ям, а бібліотечні —
через FQCN `datamonitor.platform.<role>`. У collection немає знань про BTC/ETH,
назв наших VM чи структури project config. Наприклад, secret_access отримує
project/secret ID/destination, power — project/zone/список VM, app_source — repo/ref/path.
Schema належить проєкту й лежить у `ansible/roles/validate/files/config.schema.json`.
Group_vars та статичного inventory немає.

## Звичайний запуск

Із кореня репозиторію:

```bash
make setup       # один раз на controller
make validate    # локальна перевірка конфіга
make start       # створити inventory і запустити наявні зупинені VM
make inventory   # показати запущені VM
make deploy      # підготувати реліз і виконати повний деплой
make deploy-ui   # підготувати реліз і оновити лише UI
```

Кореневий ansible.cfg задає project roles та source/third-party collections; активувати
venv вручну не потрібно. Потрібні Git, Docker daemon, gcloud, чинні ADC та IAP
credentials, дозволений SSH-ключ і довірені host keys. Оператору потрібні Compute
read/start permissions та IAP-доступ; publisher — Writer на своєму repository.
Make не запускає Terraform і не створює відсутні VM.

## Inventory та конфіг

`make configure` спочатку виконує JSON schema validation, потім генерує
`.deploy/inventory.gcp.yaml` із project, zone та потрібних VM у config.json.
Стандартний `google.cloud.gcp_compute` отримує актуальні IP з GCP API, вибираючи
лише RUNNING VM. Вручну список адрес не підтримується. Кастомного Python-плагіна,
статичного inventory та group_vars немає.

Групи: bastion, internal та група кожного сервісу. Додаткові `os_ubuntu`/`os_debian`
формуються за оголошеним у конфігу boot image, а не за віддаленими SSH facts.
У режимі cloud_sql + postgres postgres VM виключається з inventory і power.
У hybrid ця VM потрібна для RabbitMQ/Redis навіть із Cloud SQL.

До bastion з'єднання йде через IAP, до application VM — через SSH forwarding
на bastion. Host-key checking збережено. `ansible.cfg` задає timeout 60 секунд,
pipelining та автоматичне визначення Python на VM. Шаблон inventory задає SSH-порти
та IAP/ProxyCommand; цих виразів у `config.json` немає. Для локальних play-ів
Make явно використовує Python контролера із `.venv`.

Для прямого виклику запускайте project playbook-и з кореня репозиторію:

```bash
.venv/bin/ansible-playbook -i localhost, ansible/playbooks/configure.yaml
.venv/bin/ansible-playbook -i .deploy/inventory.gcp.yaml ansible/playbooks/site.yaml \
  -e @.deploy/releases/RELEASE.json --limit ui
```

Project playbook-и підтримують DATAMONITOR_ROOT/DATAMONITOR_CONFIG для іншого
шляху конфіга. Бібліотечна collection сама project config не читає. Прямі ad-hoc
ansible-команди потребують `-e @config.json`.
Синтаксис без GCP API можна перевірити через `-i localhost, ... --syntax-check`;
попередження про відсутні remote-групи тоді очікувані.

## Валідація та порядок

Validate — перша роль. Схема перевіряє структуру/типи, assert перевіряє зв'язки
між полями (унікальні IP, zone/region, відповідність firewall тегам і портам).
Результат запам'ятовується тільки в пам'яті localhost на час одного Ansible
execution: наступні play-и не повторюють schema validation. Окремий точковий
playbook також перевіряє конфіг, у тому числі з --limit ui, до SSH/змін VM.

Controller release: validate → inventory → power → images.
Site: validate → bastion → prepare → postgres → history → fetcher → ui.
Remote play-и використовують connection перед функціональними ролями.
Prepare встановлює common/docker на internal та Ops Agent, якщо monitoring.enabled=true.

## Образи, секрети та перевірки

Перед новим релізом commit і push змін у DataFetcher обов'язкові. Images використовує
`community.docker.docker_image` та `docker_image_push`, immutable commit tags і
записує digest manifest у `.deploy/releases/<application-commit>.json`.
Application commit визначається за змінами DataFetcher без Markdown-документації.
Існуючий manifest повторно використовується; infrastructure-only commit не
спричиняє перебудову. Відкат: `make deploy RELEASE=/absolute/path/release.json`.
Це відкат образів/assets, а не даних чи схеми БД.

VM отримують Git assets того самого commit, власний env через metadata/Secret
Manager URI та образи за sha256. Build на VM вимкнений. Env root:0600, no_log,
diff вимкнений. Старий спільний env видаляється після перевірок сервісу.

Compose має окремі render/start/cleanup, непорожній список сервісів і bounded
json-file logs (10m × 3). App-контейнери non-root/read-only, cap_drop ALL,
no-new-privileges і /tmp tmpfs. Nginx зберігає потрібні штатні capabilities для TLS,
але має read-only rootfs/tmpfs. DB/broker/cache зберігають writable volumes.
HTTPS renewal залишається в block/always, nginx перевіряється через Docker exec module.

CLI залишений для Git introspection, отримання короткоживучого ADC token,
Certbot та діагностичних sshd/fail2ban команд. Вони мають окреме призначення;
паролі й токени не виводяться. SQL initialization належить History, а не
дублюється Ansible-командами. Моніторинг цією реалізацією не змінюється.

## Моніторинг

`prepare.yaml` встановлює `datamonitor.platform.ops_agent`, якщо
`monitoring.enabled=true`. Для окремого запуску: `ansible/playbooks/monitoring.yaml`.
Agent збирає системні метрики на application VM; IAM, dashboard, policies та
uptime check належать Terraform. [Інструкція Google Cloud Console](../gcp-terra/MONITORING.md).

SSH forwarding використовує ім’я Bastion як SSH identity: IAP сам визначає
GCE endpoint. На новому controller потрібно перевірити й довірити також ключ
`[BASTION_NAME]:SSH_PORT`, окрім ключів приватних IP; host-key checking не вимикається.
