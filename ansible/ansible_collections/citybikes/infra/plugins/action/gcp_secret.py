# -*- coding: utf-8 -*-
"""Action plugin citybikes.infra.gcp_secret: the value of a secret in Secret Manager.
Straight from the Secret Manager API (google-auth + requests), with the key of infra/bootstrap: it compares the
value with the latest version and adds a new version only when it differs. It never CREATES a secret: Terraform
makes them (empty), only their values are ours. A secret with no version yet simply has no value yet."""

import base64
import json
import os

from ansible.errors import AnsibleActionFail
from ansible.plugins.action import ActionBase

API = "https://secretmanager.googleapis.com/v1/projects/{project}/secrets/{name}"


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


def session_for(credentials):
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account

    return AuthorizedSession(service_account.Credentials.from_service_account_file(
        credentials, scopes=["https://www.googleapis.com/auth/cloud-platform"]))


def error_of(response):
    """GCP's own message, never the request (it may hold the value)."""
    try:
        return response.json()["error"]["message"]
    except (ValueError, KeyError, TypeError):
        return "HTTP %s" % response.status_code


def latest_value(session, secret_url):
    """The value of the latest version, or None when there is none yet (no version, or the latest one disabled
    or destroyed). A missing secret is an error: Terraform makes the secrets."""
    response = session.get(secret_url)
    if response.status_code == 404:
        raise AnsibleActionFail("The secret %s does not exist: make it with the infrastructure first (terraform apply)"
                                % secret_url.rsplit("/", 1)[1])
    if not response.ok:
        raise AnsibleActionFail(error_of(response))

    response = session.get(secret_url + "/versions/latest:access")
    if response.status_code in (404, 400):  # 404: no version yet; 400 FAILED_PRECONDITION: latest disabled/destroyed
        return None
    if not response.ok:
        raise AnsibleActionFail(error_of(response))
    return base64.b64decode(response.json()["payload"]["data"]).decode("utf-8")


def add_version(session, secret_url, value):
    payload = {"payload": {"data": base64.b64encode(value.encode("utf-8")).decode("ascii")}}
    response = session.post(secret_url + ":addVersion", json=payload)
    if not response.ok:
        raise AnsibleActionFail(error_of(response))


class ActionModule(ActionBase):
    TRANSFERS_FILES = False

    def run(self, tmp=None, task_vars=None):
        result = super().run(tmp, task_vars)
        _, args = self.validate_argument_spec(argument_spec=dict(
            name=dict(type="str", required=True),
            value=dict(type="str", required=True, no_log=True),
        ))

        credentials = credentials_file()
        secret_url = API.format(project=project_of(credentials), name=args["name"])
        session = session_for(credentials)

        changed = latest_value(session, secret_url) != args["value"]
        if changed and not self._play_context.check_mode:
            add_version(session, secret_url, args["value"])

        # only what says what happened: never the value
        result.update(changed=changed, name=args["name"])
        return result
