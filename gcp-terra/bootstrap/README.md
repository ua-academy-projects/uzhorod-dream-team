# Bootstrap

Bash-скрипт готує GCP для Terraform: створює відсутні project, service account
і bucket, вмикає API, надає права та зберігає JSON-ключ локально.
Повторний запуск використовує наявні ресурси й ключ.

Потрібні Bash, jq та gcloud. Запускайте з адміністративного Google-акаунта.
Локальна копія jq у `.tools/` підхоплюється скриптом автоматично та виключена з Git.

1. Скопіюйте `bootstrap.config.example.json` у `bootstrap.local.json`, якщо
   локального файла ще немає, і заповніть параметри. Для нового проєкту
   потрібен `billing_account_id`. `folder_id` / `organization_id` необов'язкові.
2. Виконайте з кореня репозиторію:

```bash
gcloud auth login
bash gcp-terra/bootstrap/bootstrap.sh
source gcp-terra/bootstrap/terraform.env.sh
```

Локальний конфіг, `.credentials/`, `terraform.env.sh` і `backend.hcl`
виключені з Git. Не комітьте ключ.

State залишається локальним. Для іншого проєкту також оновіть project/region/zone
в основному `config.json` перед запуском Terraform.
