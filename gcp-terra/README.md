# GCP: Registry, firewall та IAP

Terraform читає `../config.json`; перед plan перевірте його через
`ansible/playbooks/validate.yaml`. `config.schema.json` зберігається в Git.
Cloud SQL вже існує й не створюється цим Terraform.

Додані ресурси: Artifact Registry Docker repository з immutable tags,
repository-scoped Reader для Fetcher/History/UI, Writer для `image_publishers`,
IAP API та instance-scoped tunnel access для `iap_members` лише на SSH-порт bastion.
Значення IAM identities не є секретами, але не підставляються автоматично з
активного gcloud account.

Наприклад, у локальному ігнорованому `gcp-terra/operators.tfvars`:

```hcl
iap_members      = ["user:YOUR_OPERATOR@example.com"]
image_publishers = ["user:YOUR_PUBLISHER@example.com"]
```

Це приклад: замініть адреси на чинні identities. Оператору також потрібні
`compute.instances.get/list` та наявний дозволений SSH-ключ. IAP не надає Linux
користувача чи SSH-ключ. Publisher використовує ADC і не потребує ролі Writer
на весь project. Якщо account уже має достатні права, `image_publishers` може
бути порожнім. Порожній `iap_members` зупиняє plan, щоб не закрити доступ до bastion.

```bash
ansible-playbook -i localhost, ansible/playbooks/validate.yaml
terraform -chdir=gcp-terra fmt -check -recursive
terraform -chdir=gcp-terra validate
terraform -chdir=gcp-terra plan -var-file=operators.tfvars -out=/tmp/datamonitor.tfplan
```

Plan повинен показувати заміну `allow-internal` точковими правилами, новий
registry/IAP та видалення публічного IP bastion. Перевірте, що немає несподіваного
перестворення VM або видалення дисків. Apply виконуйте лише за окремого доручення
на розгортання, після перегляду plan. Для першої міграції може знадобитися активний
адміністратор із правами ввімкнення API/керування Registry та IAP IAM; не додавайте
широкі постійні ролі terraform-deployer для зручності. Існуючий bootstrap не
отримує нових постійних прав цими змінами.

Firewall дозволяє:

| Джерело | Ціль | TCP |
|---|---|---|
| IAP `35.235.240.0/20` | bastion | 56789 |
| bastion | application VM | 22 |
| UI | History | 8000 |
| History | Fetcher | 8000 |
| Fetcher/History | PostgreSQL VM | 5432, лише database.provider=container |
| Fetcher/History | RabbitMQ | 5672, лише app_backend=hybrid |
| UI | Redis | 6379, лише app_backend=hybrid |
| Internet | UI | 80, 443 |

Інші вхідні з'єднання блокує implied ingress deny VPC. Cloud SQL private access
і вихідний доступ VM через NAT не змінено. `admin_ip_cidr` залишений як необов'язковий
legacy input для сумісності з локальним bootstrap env, поточні правила його не використовують.

Після погодженого apply перевірте SSH з controller:

```bash
ansible -i ansible/inventory.gcp.yaml bastion -m ping
ansible -i ansible/inventory.gcp.yaml internal -m ping
```

Ansible inventory задає IAP ProxyCommand і forwarding через bastion самостійно.
Якщо VM зупинені, динамічний inventory не показує їх. Не запускайте VM автоматично
для локального review. Інструкції збірки, manifest і деплою — в `ansible/README.md`.
