# Початкова підготовка project та Terraform backend

bootstrap.sh готує project/billing за конфігом, API, terraform-deployer account,
його права та GCS state bucket. Наявні ресурси й локальний ключ використовуються
повторно. Ключ, terraform.env.sh, backend.hcl і .credentials/ виключені з Git.

Потрібні Bash, jq та gcloud. Із кореня репозиторію, з адміністративного account:

```bash
gcloud auth login
bash gcp-terra/bootstrap/bootstrap.sh
source gcp-terra/bootstrap/terraform.env.sh
terraform -chdir=gcp-terra init -backend-config=bootstrap/backend.hcl
```

На першому перенесенні локального state використовуйте -migrate-state лише після
перевірки джерела state. Bootstrap не запускає VM, application deployment, Cloud SQL
створення чи private-service peering. Це належить Terraform та Ansible collection.

Наявний Cloud SQL і private services access приймаються через декларативні imports
з cloud_sql.adopt_existing=true. Для нового середовища прапорець false, а ресурси
створює модуль cloud-sql. Порядок, обмеження та IAM описані в ../README.md.

Постійні права terraform-deployer не розширювалися для цього переходу. Import/API/IAM
міграція може потребувати активного адміністраторського account і тимчасового
GOOGLE_OAUTH_ACCESS_TOKEN; не друкуйте token та не додавайте його в конфіг чи Git.
