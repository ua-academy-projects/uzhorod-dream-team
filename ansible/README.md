# Ansible

- `inventory.yaml` — VM, групи та SSH-параметри; внутрішні IP використовують
  ProxyJump із локального `~/.ssh/config`.
- `playbooks/prepare.yaml` — базові пакети й Docker для VM групи `internal`.
- `playbooks/bastion.yaml` — SSH, UFW і fail2ban на bastion; Docker не встановлюється.
- `playbooks/fetcher.yaml`, `playbooks/history.yaml` — деплой відповідного сервісу.
- `playbooks/postgres.yaml` — PostgreSQL/RabbitMQ/Redis відповідно до режиму.
- `playbooks/ui.yaml` — UI, nginx та HTTPS із поновленням сертифіката.
- `roles/secret_access` — отримання env із Secret Manager через service account VM.
- `requirements.yaml` — `community.docker` для Compose v2 та `community.general` для UFW.

Конфіг передається з кореневого `config.json` через `vars_files`.
Fetcher, History, PostgreSQL VM та UI читають власні секрети під час деплою через Ansible `uri`
і записують env на відповідну VM з правами `0600`. Локальні env-файли,
gcloud і власні Python/Bash-скрипти для цього не потрібні.
Секретні задачі мають `no_log: true`, запис env — також `diff: false`.

Передумови: підготовлені й наповнені секрети, відповідний service account
на кожній VM та Secret Accessor на її секреті. Terraform startup має бути
вимкнений для Fetcher, History, PostgreSQL VM та UI. Див. [ENVIRONMENTS.md](ENVIRONMENTS.md).

Із папки `ansible`:

```bash
ansible-galaxy collection install -r requirements.yaml
ansible-playbook -i inventory.yaml playbooks/prepare.yaml
ansible-playbook -i inventory.yaml playbooks/postgres.yaml --syntax-check
ansible-playbook -i inventory.yaml playbooks/postgres.yaml
ansible-playbook -i inventory.yaml playbooks/history.yaml --syntax-check
ansible-playbook -i inventory.yaml playbooks/history.yaml
ansible-playbook -i inventory.yaml playbooks/fetcher.yaml --syntax-check
ansible-playbook -i inventory.yaml playbooks/fetcher.yaml
ansible-playbook -i inventory.yaml playbooks/ui.yaml --syntax-check
ansible-playbook -i inventory.yaml playbooks/ui.yaml
```

Підготовку повторюйте за потреби, коли змінюються пакети чи Docker.
Подробиці деплою: `roles/fetcher/README.md`, `roles/history/README.md`.

Опис ролі PostgreSQL VM: `roles/postgres/README.md`.

Опис UI, портів та HTTPS: `roles/ui/README.md`.

Опис bastion, SSH та переходу від bootstrap: `roles/bastion/README.md`.
