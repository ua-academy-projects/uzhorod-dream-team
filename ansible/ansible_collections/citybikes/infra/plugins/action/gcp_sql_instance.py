# -*- coding: utf-8 -*-
"""Action plugin citybikes.infra.gcp_sql_instance: is there a Cloud SQL instance of this name, and its private IP.
A wrapper around google.cloud.gcp_sql_instance_info (it lists the instances of the project); this plugin adds
who we are (the key, its project) and picks the one instance by its name."""

import json
import os

from ansible.errors import AnsibleActionFail
from ansible.plugins.action import ActionBase


def credentials_file():
    """The key file of the service account (infra/bootstrap/terraform.env sets the variable)."""
    path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not path:
        raise AnsibleActionFail("GOOGLE_APPLICATION_CREDENTIALS is not set: source infra/bootstrap/terraform.env")
    return path


def project_of(credentials):
    """The project is the one of the key."""
    with open(credentials, encoding="utf-8") as f:
        return json.load(f)["project_id"]


def private_address(instance):
    """The private IP of a Cloud SQL instance (its "ipAddresses" of type PRIVATE), or "" if it has none."""
    return next((a["ipAddress"] for a in instance.get("ipAddresses", []) if a.get("type") == "PRIVATE"), "")


class ActionModule(ActionBase):
    TRANSFERS_FILES = False

    def run(self, tmp=None, task_vars=None):
        result = super().run(tmp, task_vars)
        _, args = self.validate_argument_spec(argument_spec=dict(name=dict(type="str", required=True)))
        credentials = credentials_file()

        found = self._execute_module(
            module_name="google.cloud.gcp_sql_instance_info",
            module_args=dict(project=project_of(credentials), auth_kind="serviceaccount",
                             service_account_file=credentials),
            task_vars=task_vars,
        )
        if found.get("failed"):
            raise AnsibleActionFail("google.cloud.gcp_sql_instance_info: %s" % found.get("msg"))

        instance = next((i for i in found.get("resources", []) if i.get("name") == args["name"]), None)
        result.update(changed=False, exists=instance is not None, private_ip=private_address(instance or {}))
        return result
    