# Моніторинг Data Monitor

Terraform module `modules/monitoring` керує дашбордом, email-каналом,
HTTPS uptime check, шістьма alert policies та IAM для запису метрик.
Параметри й пороги — у `config.json → monitoring`.
Ansible collection role `datamonitor.platform.ops_agent` встановлює Ops Agent
на application VM. Він збирає системні метрики раз на 60 секунд; збір syslog
вимкнений. Додатковий `roles/logging.logWriter` не надається.

| Перевірка | Поріг | Тривалість |
|---|---|---|
| VM CPU | > 80% | 5 хв |
| VM disk used | > 80% | 5 хв |
| VM memory used | > 90% | 5 хв |
| Cloud SQL CPU | > 80% | 5 хв |
| Cloud SQL disk used | > 80% | 5 хв |
| HTTPS `/` | щонайменше 2 невдалих checker series | 3 хв |

Для CPU та Cloud SQL API використовує частку `0–1`, а Ops Agent для memory/disk —
`0–100`. Terraform перетворює спільні пороги з JSON у потрібні одиниці.
CPU контролюється на всіх наявних VM, disk/memory — на чотирьох application VM.
Bastion не має service account, Ops Agent на нього не встановлюється.
Cloud SQL metrics збираються GCP без встановлення агента.
HTTPS check перевіряє довірений TLS-сертифікат і HTTP 2xx, але не замінює
перевірку актуальності цін та доступності PostgreSQL/Redis.

## Як подивитися в Google Cloud Console

1. Вибери project із `config.json → project_id`.
2. Відкрий **Monitoring → Dashboards → Data Monitor overview**.
3. Вибери проміжок **Last 1 hour**. Після першого встановлення агента зачекай
   кілька хвилин; CPU/SQL та agent metrics можуть надходити із затримкою.
4. Відкрий **Monitoring → Alerting → Policies**. Знайди політики з префіксом
   **Data Monitor:**. Перевір умову, поріг, тривалість та notification channel.
5. У **Monitoring → Uptime checks → Data Monitor HTTPS** перевір адресу,
   HTTPS, path `/`, SSL validation і результати перевірок.
6. У **Monitoring → Alerting → Edit notification channels → Email** знайди
   **Data Monitor operator**. Якщо Console просить верифікацію, заверши її
   з пошти. Якщо доступна кнопка **Send test notification**, надішли тест і
   перевір Inbox/Spam. Відсутність інцидентів сама собою не підтверджує доставку email.

## Як створити аналог вручну в UI

Для навчання використовуй інші назви: ресурси, якими вже керує Terraform,
не варто дублювати або редагувати без подальшого узгодження з кодом.

### Графік CPU VM

1. **Monitoring → Metrics explorer → Select a metric**.
2. Вибери **VM Instance → Instance → CPU utilization**
   (`compute.googleapis.com/instance/cpu/utilization`).
3. Додай filter **instance_id** для потрібних VM. ID видно в
   **Compute Engine → VM instances → назва VM → Details**.
4. Вибери alignment **Mean**, interval **1 minute**; збережи окремі series
   для кожної VM, щоб середнє між VM не приховало перевантажену машину.
5. **Save chart → New dashboard**, дай дашборду назву.

### Диск і пам'ять VM

1. Спочатку встанови Ops Agent: у цьому проєкті це робить
   `ansible/playbooks/monitoring.yaml`, а повний `make deploy` — через prepare.
   Саме створення графіка агент не встановлює.
2. У **Metrics explorer** знайди **Disk utilization**
   (`agent.googleapis.com/disk/percent_used`). Увімкни показ неактивних метрик,
   якщо щойно встановлений агент ще не передав дані.
3. Додай **state = used**, відфільтруй потрібні VM; для розбору конкретного
   диска також вибери `device`. Додай виключення **device does not start with /dev/loop**:
   Snap loop-образи read-only і нормально показують 100%. Terraform виключає їх
   і з графіка, і з алерта. Не підсумовуй частки різних дисків.
4. Для memory вибери **Memory percent used**
   (`agent.googleapis.com/memory/percent_used`) та **state = used**.
5. Збережи графіки в дашборд.

### Алерт за порогом

1. **Monitoring → Alerting → Create policy → Select a metric**.
2. Вибери ту саму метрику та filters, що для графіка.
3. Alignment **Mean**, **1 minute**, без усереднення між різними VM/дисками.
4. **Configure trigger → Any time series violates → Above threshold**.
5. Для CPU задай **80%** (або **0.8**, якщо поле показує частку), для disk
   **80**, для memory **90**. Перевір одиниці, які показує Console.
6. Retest window **5 minutes**, notification channel **Data Monitor operator**.
7. Додай зрозумілу назву та опис дій, натисни **Create policy**.

### Cloud SQL

1. У **Metrics explorer** вибери resource **Cloud SQL Database**.
2. Вибери **CPU utilization** (`cloudsql.googleapis.com/database/cpu/utilization`)
   або **Disk utilization** (`cloudsql.googleapis.com/database/disk/utilization`).
3. Filter **database_id = PROJECT_ID:datamonitor**, звір instance name з конфігом.
4. Збережи графік. Створи threshold alert **80% / 5 minutes**, як вище.

### HTTPS uptime

1. **Monitoring → Uptime checks → Create uptime check**.
2. Protocol **HTTPS**, resource **URL**, адреса — поточний public IP UI з
   Terraform outputs, path `/`, port **443**.
3. Період **1 minute**, timeout **10 seconds**, SSL certificate validation
   увімкнена, accepted responses **2xx**.
4. Вибери регіони Europe, USA та Asia Pacific; натисни **Test**, потім **Create**.
5. Для відповідного алерта відкрий **Alerting → Create policy**, metric
   `monitoring.googleapis.com/uptime_check/check_passed`, resource **Uptime URL**.
   Додай filter **check_id** саме створеної перевірки.
6. В advanced aggregation задай alignment **Next older**, **1 minute**,
   cross-series reducer **Count false**, group by **host**. Так отримуєш
   кількість невдалих checker series, а не середнє boolean-значення.
7. Condition **Above 1**, retest **3 minutes**, email channel **Data Monitor operator**.
   Це відповідає щонайменше двом невдалим checker series. Перевір зведення умови
   перед Save; доступні назви пунктів UI можуть відрізнятися.

## Як далі змінювати через код

1. Відредагуй пороги в `config.json → monitoring`.
2. `make validate`.
3. Ініціалізуй Terraform згідно з `README.md`, підготуй та переглянь plan.
4. Застосуй лише переглянутий plan. `make deploy` Terraform не запускає.
5. Для змін Ops Agent запусти з кореня:

   ```bash
   make configure
   .venv/bin/ansible-playbook ansible/playbooks/monitoring.yaml
   ```

Ресурси спочатку створені через Monitoring API та імпортовані в Terraform.
Наявний сторонній dashboard не видаляється. Подальші зміни зберігай у коді,
щоб наступний apply не скасував ручні зміни Console.

Офіційна довідка: [Ops Agent](https://docs.cloud.google.com/monitoring/agent/ops-agent/configuration),
[Uptime checks](https://docs.cloud.google.com/monitoring/uptime-checks).
