# -*- coding: utf-8 -*-
"""Action plugin citybikes.infra.gcp_sql_user: a user of a Cloud SQL instance whose password is the value of
a secret. A wrapper around google.cloud.gcp_sql_user, which creates the user. That module cannot change the
password of a user that exists (the API never returns a password, so it sees no difference): this plugin does
it itself. Which version of the secret the password is, is kept in the label sql-user-version of the secret:
a new version of the secret = a new password, otherwise nothing happens."""

import base64
import json
import os
import time

from ansible.errors import AnsibleActionFail
from ansible.plugins.action import ActionBase

SECRET_URL = "https://secretmanager.googleapis.com/v1/projects/{project}/secrets/{secret}"
SQL_URL = "https://sqladmin.googleapis.com/v1/projects/{project}"
LABEL = "sql-user-version"


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


def session_of(credentials):
    """An HTTP session that signs every request with the key (google-auth)."""
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account

    return AuthorizedSession(service_account.Credentials.from_service_account_file(
        credentials, scopes=["https://www.googleapis.com/auth/cloud-platform"]))


def latest_version(session, project, secret):
    """The number and the value of the latest version of the secret."""
    response = session.get(SECRET_URL.format(project=project, secret=secret) + "/versions/latest:access")
    if response.status_code == 404:
        raise AnsibleActionFail("the secret %s has no value yet: ansible-playbook citybikes.infra.secrets" % secret)
    response.raise_for_status()
    body = response.json()
    return body["name"].rsplit("/", 1)[1], base64.b64decode(body["payload"]["data"]).decode("utf-8")


def secret_labels(session, project, secret):
    response = session.get(SECRET_URL.format(project=project, secret=secret))
    response.raise_for_status()
    return response.json().get("labels", {})


def set_secret_labels(session, project, secret, labels):
    """All the labels of the secret (the ones it has + ours): updateMask=labels replaces the whole map."""
    response = session.patch(SECRET_URL.format(project=project, secret=secret),
                             params={"updateMask": "labels"}, json={"labels": labels})
    response.raise_for_status()


def user_exists(session, project, instance, name):
    response = session.get(SQL_URL.format(project=project) + "/instances/%s/users" % instance)
    if response.status_code == 404:
        raise AnsibleActionFail("the Cloud SQL instance %s does not exist in the project %s" % (instance, project))
    response.raise_for_status()
    return any(user["name"] == name for user in response.json().get("items", []))


def set_password(session, project, instance, name, password, timeout=300):
    response = session.put(SQL_URL.format(project=project) + "/instances/%s/users" % instance,
                           params={"name": name}, json={"name": name, "password": password})
    response.raise_for_status()
    wait_for(session, project, response.json()["name"], timeout)


def wait_for(session, project, operation, timeout):
    """Cloud SQL changes things in the background: wait until its operation is DONE."""
    deadline = time.time() + timeout
    while True:
        response = session.get(SQL_URL.format(project=project) + "/operations/" + operation)
        response.raise_for_status()
        body = response.json()
        if body.get("status") == "DONE":
            if body.get("error"):
                raise AnsibleActionFail("Cloud SQL: %s" % body["error"])
            return
        if time.time() > deadline:
            raise AnsibleActionFail("the Cloud SQL operation %s is not done after %s s" % (operation, timeout))
        time.sleep(2)


class ActionModule(ActionBase):
    TRANSFERS_FILES = False

    def run(self, tmp=None, task_vars=None):
        result = super().run(tmp, task_vars)
        _, args = self.validate_argument_spec(argument_spec=dict(
            instance=dict(type="str", required=True),
            name=dict(type="str", required=True),
            password_secret=dict(type="str", required=True),
        ))
        instance, name, secret = args["instance"], args["name"], args["password_secret"]

        credentials = credentials_file()
        project = project_of(credentials)
        session = session_of(credentials)

        version, password = latest_version(session, project, secret)
        labels = secret_labels(session, project, secret)
        exists = user_exists(session, project, instance, name)

        if exists and labels.get(LABEL) == version:
            result.update(changed=False, msg="%s has the password of %s version %s" % (name, secret, version))
            return result

        result.update(changed=True, msg="%s %s the password of %s version %s"
                      % (name, "got" if exists else "was created with", secret, version))
        if self._task.check_mode:
            return result

        if exists:
            set_password(session, project, instance, name, password)
        else:
            created = self._execute_module(
                module_name="google.cloud.gcp_sql_user",
                module_args=dict(
                    name=name,
                    host="", 
                    password=password,
                    instance={"name": instance},
                    state="present",
                    project=project,
                    auth_kind="serviceaccount",
                    service_account_file=credentials,
                ),
                task_vars=task_vars,
            )
            if created.get("failed"):
                raise AnsibleActionFail("google.cloud.gcp_sql_user: %s" % created.get("msg"))

        set_secret_labels(session, project, secret, dict(labels, **{LABEL: version}))
        return result