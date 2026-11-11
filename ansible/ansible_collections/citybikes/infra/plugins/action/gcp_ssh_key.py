# -*- coding: utf-8 -*-
"""Action plugin citybikes.infra.gcp_ssh_key: a public SSH key on a VM for a few minutes.
The key goes to the VM's metadata "ssh-keys" with "expireOn"; the Google guest agent on the VM adds it to the
user's authorized_keys and takes it out again when it expires. "ssh-keys" belongs to Ansible (Terraform ignores
it): every run keeps the keys that are still valid, drops the expired and the permanent ones, adds the new one."""

import datetime
import json
import os

from ansible.errors import AnsibleActionFail
from ansible.plugins.action import ActionBase

INSTANCE_URL = "https://compute.googleapis.com/compute/v1/projects/{project}/zones/{zone}/instances/{name}"
TIME_FORMAT = "%Y-%m-%dT%H:%M:%S+0000"


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


def key_line(user, public_key, expire_on):
    """One line of "ssh-keys": user:type key google-ssh {"userName": ..., "expireOn": ...}."""
    key_type, key_body = public_key.split()[:2]
    return "%s:%s %s google-ssh %s" % (user, key_type, key_body,
                                       json.dumps({"userName": user, "expireOn": expire_on.strftime(TIME_FORMAT)}))


def expires(line):
    """When a line expires, or None for a permanent key (no "google-ssh {...expireOn...}")."""
    if " google-ssh " not in line:
        return None
    try:
        expire_on = json.loads(line.split(" google-ssh ", 1)[1])["expireOn"]
        return datetime.datetime.strptime(expire_on, TIME_FORMAT).replace(tzinfo=datetime.timezone.utc)
    except (ValueError, KeyError):
        return None


def new_ssh_keys(current, user, public_key, now, ttl_minutes):
    """The value of "ssh-keys" after this run: the valid temporary keys (but not an older line of this same
    key) + this key until now + ttl."""
    key_body = public_key.split()[1]
    kept = [line for line in current.splitlines()
            if line.strip() and key_body not in line and (expires(line) or now) > now]
    return "\n".join(kept + [key_line(user, public_key, now + datetime.timedelta(minutes=ttl_minutes))])


def set_ssh_keys(session, url, value):
    """Write "ssh-keys" and keep every other metadata item; the fingerprint makes GCP refuse a stale write."""
    response = session.get(url)
    if response.status_code == 404:
        raise AnsibleActionFail("the VM %s does not exist" % url.rsplit("/", 1)[1])
    response.raise_for_status()
    metadata = response.json().get("metadata", {})
    items = [item for item in metadata.get("items", []) if item["key"] != "ssh-keys"]
    current = next((item["value"] for item in metadata.get("items", []) if item["key"] == "ssh-keys"), "")
    value = value(current)
    response = session.post(url + "/setMetadata", json={
        "fingerprint": metadata.get("fingerprint"),
        "items": items + [{"key": "ssh-keys", "value": value}],
    })
    response.raise_for_status()
    operation = response.json()["selfLink"]
    session.post(operation + "/wait").raise_for_status()


class ActionModule(ActionBase):
    TRANSFERS_FILES = False

    def run(self, tmp=None, task_vars=None):
        result = super().run(tmp, task_vars)
        _, args = self.validate_argument_spec(argument_spec=dict(
            instance=dict(type="str", required=True),
            zone=dict(type="str", required=True),
            user=dict(type="str", required=True),
            public_key=dict(type="str", required=True),
            ttl_minutes=dict(type="int", default=15),
        ))
        credentials = credentials_file()
        project = project_of(credentials)
        url = INSTANCE_URL.format(project=project, zone=args["zone"], name=args["instance"])
        now = datetime.datetime.now(datetime.timezone.utc)
        until = now + datetime.timedelta(minutes=args["ttl_minutes"])

        result.update(changed=True, msg="%s may log in to %s until %s UTC"
                      % (args["user"], args["instance"], until.strftime("%H:%M")))
        if self._task.check_mode:
            return result
        set_ssh_keys(session_of(credentials), url,
                     lambda current: new_ssh_keys(current, args["user"], args["public_key"], now, args["ttl_minutes"]))
        return result