#!/usr/bin/python

from __future__ import annotations

DOCUMENTATION = r"""
---
module: gce_sql_instance_info
short_description: List Cloud SQL instances of a project by user labels
description:
  - Reads the Cloud SQL instances of one project through the Cloud SQL Admin API, filtered by user labels.
  - Changes nothing.
version_added: 1.1.0
author:
  - ISS position tracker (@iss-position-tracker)
options:
  project:
    description: Project ID.
    type: str
    required: true
  filters:
    description: User labels an instance must have, as label name to value; sent to the API as a quoted filter and checked again for an exact match.
    type: dict
    default: {}
  auth_kind:
    description: Only C(serviceaccount) is supported.
    type: str
    choices: [serviceaccount]
    default: serviceaccount
  service_account_file:
    description: Path to the service account key. Defaults to the E(GCP_SERVICE_ACCOUNT_FILE) environment variable.
    type: path
    required: true
  api_endpoint:
    description: Cloud SQL Admin API endpoint.
    type: str
    default: https://sqladmin.googleapis.com
requirements:
  - google-auth
  - requests
attributes:
  check_mode:
    support: full
    description: The module only reads.
  diff_mode:
    support: none
    description: No diff is returned.
"""

EXAMPLES = r"""
- name: Find the Cloud SQL instance of the stand
  iss.platform.gce_sql_instance_info:
    project: my-project
    filters:
      iss-prefix: iss
  delegate_to: localhost
  register: sql
"""

RETURN = r"""
instances:
  description: Matching instances.
  returned: always
  type: list
  elements: dict
  contains:
    name:
      description: Instance name.
      type: str
    connection_name:
      description: Connection name C(project:region:instance).
      type: str
    state:
      description: Instance state, for example C(RUNNABLE).
      type: str
    private_ip:
      description: Private IP address, or null.
      type: str
"""

from ansible.module_utils.basic import AnsibleModule, env_fallback, missing_required_lib
from ansible_collections.iss.platform.plugins.module_utils.gce import (
    GOOGLE_IMP_ERR,
    GceApiError,
    authorized_session,
    list_all,
)

SCOPES = ["https://www.googleapis.com/auth/sqlservice.admin"]


def instance_filter(filters):
    if not filters:
        return None
    return " AND ".join(
        'settings.userLabels.%s:"%s"' % (key, str(value).replace("\\", "\\\\").replace('"', '\\"')) for key, value in filters.items()
    )


def labels_match(instance, filters):
    labels = (instance.get("settings") or {}).get("userLabels") or {}
    return all(labels.get(key) == str(value) for key, value in filters.items())


def summarize(instance):
    private = [a.get("ipAddress") for a in instance.get("ipAddresses") or [] if a.get("type") == "PRIVATE"]
    return {
        "name": instance.get("name"),
        "connection_name": instance.get("connectionName"),
        "state": instance.get("state"),
        "private_ip": private[0] if private else None,
    }


def list_instances(session, endpoint, project, filters):
    url = "%s/v1/projects/%s/instances" % (endpoint.rstrip("/"), project)
    query = instance_filter(filters)
    return [i for i in list_all(session, url, {"filter": query} if query else {}) if labels_match(i, filters)]


def main():
    module = AnsibleModule(
        argument_spec=dict(
            project=dict(type="str", required=True),
            filters=dict(type="dict", default={}),
            auth_kind=dict(type="str", choices=["serviceaccount"], default="serviceaccount"),
            service_account_file=dict(type="path", required=True, fallback=(env_fallback, ["GCP_SERVICE_ACCOUNT_FILE"])),
            api_endpoint=dict(type="str", default="https://sqladmin.googleapis.com"),
        ),
        supports_check_mode=True,
    )
    if GOOGLE_IMP_ERR is not None:
        module.fail_json(msg=missing_required_lib("google-auth and requests"), exception=GOOGLE_IMP_ERR)

    p = module.params
    try:
        session = authorized_session(p["service_account_file"], SCOPES)
    except (OSError, ValueError) as e:
        module.fail_json(msg="cannot read service account file %s: %s" % (p["service_account_file"], e))
    try:
        instances = list_instances(session, p["api_endpoint"], p["project"], p["filters"])
    except GceApiError as e:
        module.fail_json(msg="Cloud SQL Admin API request failed: %s" % e)
    module.exit_json(changed=False, instances=[summarize(i) for i in instances])


if __name__ == "__main__":
    main()
