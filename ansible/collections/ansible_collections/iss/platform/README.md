# iss.platform

Base OS configuration for Ubuntu VMs on Google Compute Engine: a temporary admin key through instance metadata, the guest agent, sshd, fail2ban, Docker and the Google Cloud Ops Agent. Nothing in it is specific to the ISS application; the project roles and the app deploy live in `iss.tracker`, which calls these roles with project values.

Requires ansible-core 2.19 or newer and `community.general`. The module and the inventory plugin need `google-auth` and `requests` on the controller.

## Inventory plugin

`iss.platform.gce` lists the instances of one project through the Compute Engine API and sets SSH connection variables for a layout with one bastion: the bastion is reached on its external IP, every other host through `ProxyCommand` to the bastion. The file name must end with `gce.yml` or `gce.yaml`; the standard `auto` plugin loads it.

| Option | Notes |
|---|---|
| `project`, `zones` | required |
| `service_account_file` | required; env `GCP_SERVICE_ACCOUNT_FILE` |
| `filters` | labels an instance must have, e.g. `{iss-prefix: iss}` |
| `group_labels` | label names whose values become groups |
| `bastion_label`, `bastion_value` | required; how the bastion is recognised |
| `admin_user` | required; `ansible_user` of every host |
| `jump_user` | required; user on the bastion for the `ProxyCommand` |
| `ssh_port` | port of the bastion (22); other hosts use 22 |
| `private_key_file`, `known_hosts_file` | required |
| `api_endpoint` | `https://compute.googleapis.com` |

Per host: `gce_internal_ip`, `ansible_host`, `ansible_user`, `ansible_port`, `ansible_ssh_private_key_file`, `ansible_ssh_common_args` (`IdentitiesOnly`, the given `known_hosts`, and the `ProxyCommand` for non-bastion hosts). Label values become group names, with characters not allowed there replaced by `_`. `private_key_file`, `known_hosts_file` and `jump_user` go into SSH arguments and must not need shell quoting (no spaces, quotes or shell characters). Instances that are not `RUNNING` are skipped with a warning. No instance, no bastion or more than one (a stopped bastion is named), a bastion without external IP, an instance without internal IP, an unreadable key file, or an API error (with Google's message) fail with a message; set `[inventory] any_unparsed_is_failed = True` in `ansible.cfg`, otherwise Ansible only warns and runs with no hosts.

```yaml
plugin: iss.platform.gce
project: my-project
zones: [changeme]
filters:
  iss-prefix: iss
group_labels: [iss-key, iss-role]
bastion_label: iss-role
bastion_value: bastion
admin_user: iss-admin
jump_user: jump
ssh_port: 2222
private_key_file: ~/.ssh/iss_gcp_ed25519
known_hosts_file: ~/.ssh/iss_gcp/known_hosts
```

## Modules

`iss.platform.gce_sql_instance_info` lists the Cloud SQL instances of a project through the Cloud SQL Admin API (`instances.list`, paged), filtered by user labels, and returns `instances: [{name, connection_name, state, private_ip}]`. It changes nothing and supports check mode. API errors fail with Google's message.

| Option | Notes |
|---|---|
| `project` | required |
| `filters` | user labels, e.g. `{iss-prefix: iss}` (default `{}`) |
| `auth_kind` | `serviceaccount` |
| `service_account_file` | env `GCP_SERVICE_ACCOUNT_FILE` |
| `api_endpoint` | `https://sqladmin.googleapis.com` |

`iss.platform.gce_ssh_key` adds or removes one user's entry in the `ssh-keys` metadata of an instance. Other users' lines stay as they are; `present` replaces every line of the user with one entry, optionally with `expire_on` (ISO 8601, written as `google-ssh {"userName", "expireOn"}`). It sends `instances.setMetadata` with the current fingerprint, waits for the zone operation and supports check mode.

| Option | Notes |
|---|---|
| `project`, `zone`, `instance`, `user` | required |
| `public_key` | required with `state: present` |
| `expire_on` | e.g. `2026-11-04T12:00:00+0000` |
| `state` | `present` (default) or `absent` |
| `auth_kind` | `serviceaccount` |
| `service_account_file` | env `GCP_SERVICE_ACCOUNT_FILE` |

## Roles

| Role | What it does | Variables (defaults) |
|---|---|---|
| `gce_temp_admin` | `main`: adds an expiring key for `gce_temp_admin_user` on localhost, waits for SSH, gathers facts. `revoke`: closes the SSH connection and removes the key | `gce_temp_admin_project`, `_zone`, `_instance`, `_public_key` (required), `_user` (`iss-admin`), `_ttl_minutes` (15) |
| `gce_guest_agent` | sets `[Accounts] deprovision_remove` so the agent deletes a user whose keys are gone; restarts the agent when it is installed | `gce_guest_agent_deprovision_remove` (true), `_config_path` (`/etc/default/instance_configs.cfg`), `_service` (`google-guest-agent`) |
| `sshd` | owns one drop-in, checks it with `sshd -t` and restores the previous file if the check fails; optionally replaces `ssh.socket` with `ssh.service` (needed for a port other than 22) | `sshd_allow_users` (required), `sshd_port` (22), `sshd_options` (no passwords, no root, no agent or X11 forwarding), `sshd_extra_options` ([]), `sshd_disable_socket` (false), `sshd_config_path` (`/etc/ssh/sshd_config.d/10-iss.conf`) |
| `fail2ban` | installs fail2ban, logs to syslog, enables the sshd jail | `fail2ban_ignoreip` ([]), `fail2ban_port` (22), `fail2ban_bantime` (1h), `fail2ban_findtime` (10m), `fail2ban_maxretry` (5) |
| `docker` | installs Docker and Compose from the Ubuntu archive, writes `/etc/docker/daemon.json` (restarts Docker when it changes; existing containers keep their log options until recreated) and starts the service | `docker_packages` (`docker.io`, `docker-compose-v2`), `docker_daemon_config` (`json-file` log driver, tag = container name, `max-size` 10m, `max-file` 3) |
| `ops_agent` | adds Google's apt repository `google-cloud-ops-agent-<codename>-<version>` (key in `/etc/apt/keyrings`, `signed-by`), installs `google-cloud-ops-agent`, writes `ops_agent_config` as `/etc/google-cloud-ops-agent/config.yaml` (merged over the built-in host metrics and syslog) and restarts the agent on change; when disabled removes package, repository and key. The VM needs a service account with `roles/logging.logWriter` and `roles/monitoring.metricWriter` | `ops_agent_enabled` (true), `ops_agent_config` ({}), `ops_agent_repo_codename` (the `distribution_release` fact), `ops_agent_repo_version` (`all`), `ops_agent_key_url`, `ops_agent_key_file` (`/etc/apt/keyrings/google-cloud-ops-agent.asc`) |

Every role validates its variables with `meta/argument_specs.yml`.

## Example

```yaml
- name: Configure a bastion through a temporary key
  hosts: bastion
  gather_facts: false
  become: true
  vars:
    gce_temp_admin_project: my-project
    gce_temp_admin_zone: changeme
    gce_temp_admin_instance: "{{ inventory_hostname }}"
    gce_temp_admin_public_key: "{{ lookup('ansible.builtin.file', '~/.ssh/id_ed25519.pub') }}"
    sshd_port: 2222
    sshd_allow_users: [jump, iss-admin@203.0.113.7/32]
    sshd_disable_socket: true
    fail2ban_port: 2222
  tasks:
    - name: Configure
      block:
        - name: Add the temporary admin key
          ansible.builtin.import_role:
            name: iss.platform.gce_temp_admin
        - name: Configure the guest agent
          ansible.builtin.import_role:
            name: iss.platform.gce_guest_agent
        - name: Configure sshd
          ansible.builtin.import_role:
            name: iss.platform.sshd
        - name: Configure fail2ban
          ansible.builtin.import_role:
            name: iss.platform.fail2ban
      always:
        - name: Revoke the temporary admin key
          ansible.builtin.import_role:
            name: iss.platform.gce_temp_admin
            tasks_from: revoke
```
