# datamonitor.platform

Reusable roles with explicit inputs. Project playbooks, application roles,
configuration schema and release policy live outside this collection.

| Role | Inputs / purpose |
|---|---|
| common | common_packages; Debian/Ubuntu base packages |
| docker | docker_packages; Docker engine/service |
| connection | Ansible connection variables; wait and minimal facts |
| app_source | app_source_repo, app_source_ref, app_source_dir |
| compose_app | compose_app_dir/template/files/services and runtime policies |
| secret_access | secret_access_project, secret_access_secret_id, secret_access_dest; metadata identity |
| ops_agent | Debian/Ubuntu host metrics every 60s, system log ingestion disabled |
| power | power_project, power_zone, power_instance_names; start existing stopped VMs |

The collection does not read a project config or choose an application's services.
No custom inventory plugin is shipped; the project currently uses the standard
`google.cloud.gcp_compute` plugin with a generated source.
