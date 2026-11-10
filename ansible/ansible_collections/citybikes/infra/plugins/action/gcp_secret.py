# -*- coding: utf-8 -*-
"""Action plugin citybikes.infra.gcp_secret: the value of a secret in Secret Manager.
A wrapper around google.cloud.gcp_secret_manager (it compares with the latest version and adds a new one only
when the value differs); this plugin adds who we are (the key, its project) and refuses to CREATE a secret:
the secrets themselves are made elsewhere, only their values are ours."""

import json
import os

from ansible.errors import AnsibleActionFail
from ansible.plugins.action import ActionBase

SECRET_URL = "https://secretmanager.googleapis.com/v1/projects/{project}/secrets/{name}"


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


def secret_exists(project, name, credentials):
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account

    session = AuthorizedSession(service_account.Credentials.from_service_account_file(
        credentials, scopes=["https://www.googleapis.com/auth/cloud-platform"]))
    response = session.get(SECRET_URL.format(project=project, name=name))
    if response.status_code == 404:
        return False
    response.raise_for_status()
    return True


class ActionModule(ActionBase):
    TRANSFERS_FILES = False

    def run(self, tmp=None, task_vars=None):
        result = super().run(tmp, task_vars)
        _, args = self.validate_argument_spec(argument_spec=dict(
            name=dict(type="str", required=True),
            value=dict(type="str", required=True, no_log=True),
        ))

        credentials = credentials_file()
        project = project_of(credentials)
        if not secret_exists(project, args["name"], credentials):
            raise AnsibleActionFail("the secret %s does not exist in the project %s" % (args["name"], project))

        module_result = self._execute_module(
            module_name="google.cloud.gcp_secret_manager",
            module_args=dict(
                name=args["name"],
                value=args["value"],
                state="present",
                return_value=False,  # the value never comes back
                project=project,
                auth_kind="serviceaccount",
                service_account_file=credentials,
            ),
            task_vars=task_vars,
        )
        # only what says what happened: never the value, never the module's arguments
        for key in ("changed", "failed", "skipped", "msg"):
            if key in module_result:
                result[key] = module_result[key]
        result["name"] = args["name"]
        return result