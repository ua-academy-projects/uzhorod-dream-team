#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Writes secrets from Secret Manager into a file ON the VM, read with the VM's own service account."""

DOCUMENTATION = r"""
module: gcp_secret_file
short_description: Secrets from Secret Manager into a file, read on the VM itself
description:
  - Runs on the VM. Reads the secrets with the VM's own service account (the metadata server), so the
    values never pass through your machine and the VM can read only what config.json allows it.
  - The file is rewritten only when its content changes. The values are never shown or returned.
options:
  path:
    description: The file.
    type: path
    required: true
  secrets:
    description: Name in the file => secret id. For I(format=raw) exactly one.
    type: dict
    required: true
  format:
    description:
      - C(env) NAME='value' lines (the .env of docker compose).
      - C(envfile) NAME=value lines (docker run --env-file).
      - C(ini) name = value lines (e.g. the credentials of certbot).
      - C(raw) the value as it is (e.g. a private key), with a final newline.
    type: str
    choices: [env, envfile, ini, raw]
    default: env
extends_documentation_fragment: [files]
"""

EXAMPLES = r"""
- name: .env of docker compose 
  citybikes.infra.gcp_secret_file:
    path: /opt/citybikes/.env
    secrets:
      DB_PASSWORD: citybikes-db-password
    mode: "0600"
"""

RETURN = r"""
"""

import base64
import json
import os
import tempfile
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from ansible.module_utils.basic import AnsibleModule # type: ignore

METADATA = "http://metadata.google.internal/computeMetadata/v1"
SECRET_MANAGER = "https://secretmanager.googleapis.com/v1"


class SecretError(Exception):
    """A secret cannot be read; the message says what to do."""


def get(url, headers):
    with urlopen(Request(url, headers=headers), timeout=10) as response:
        return response.read().decode("utf-8")


def read_secret(project, secret_id, token):
    url = "%s/projects/%s/secrets/%s/versions/latest:access" % (SECRET_MANAGER, project, secret_id)
    try:
        body = json.loads(get(url, {"Authorization": "Bearer " + token}))
    except HTTPError as error:
        if error.code in (400, 404):
            raise SecretError("%s has no value yet: fill it in (infra/fill-secrets.sh)" % secret_id)
        if error.code == 403:
            raise SecretError("this VM may not read %s: add it to its \"secrets\" in config.json" % secret_id)
        raise SecretError("%s: HTTP %s" % (secret_id, error.code))
    return base64.b64decode(body["payload"]["data"]).decode("utf-8")


def render(file_format, values):
    """The file's content. values: name => secret value (in the order given)."""
    if file_format == "raw":
        if len(values) != 1:
            raise SecretError("format raw takes exactly one secret")
        value = next(iter(values.values()))
        return value if value.endswith("\n") else value + "\n"

    lines = []
    for name, value in values.items():
        if "\n" in value:
            raise SecretError("%s: a value with a line break fits only format raw" % name)
        if file_format == "env":
            if "'" in value:
                raise SecretError("%s: a value with ' does not fit a docker compose .env" % name)
            lines.append("%s='%s'" % (name, value))
        elif file_format == "envfile":
            lines.append("%s=%s" % (name, value))
        else:
            lines.append("%s = %s" % (name, value))
    return "\n".join(lines) + "\n"


def write_if_changed(module, path, content):
    """True when the file changed. Written next to the target and moved over it: never half a file."""
    if os.path.exists(path):
        with open(path, encoding="utf-8") as current:
            if current.read() == content:
                return False
    if module.check_mode:
        return True
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w", encoding="utf-8") as new:
        new.write(content)
    os.chmod(tmp, 0o600)
    module.atomic_move(tmp, path)
    return True


def main():
    module = AnsibleModule(
        argument_spec=dict(
            path=dict(type="path", required=True),
            secrets=dict(type="dict", required=True),
            format=dict(type="str", choices=["env", "envfile", "ini", "raw"], default="env"),
        ),
        add_file_common_args=True,
        supports_check_mode=True,
    )
    p = module.params
    try:
        flavor = {"Metadata-Flavor": "Google"}
        project = get(METADATA + "/project/project-id", flavor)
        token = json.loads(get(METADATA + "/instance/service-accounts/default/token", flavor))["access_token"]
        values = {name: read_secret(project, secret_id, token) for name, secret_id in p["secrets"].items()}
        changed = write_if_changed(module, p["path"], render(p["format"], values))
    except SecretError as error:
        module.fail_json(msg=str(error))

    file_args = module.load_file_common_arguments(p)
    if os.path.exists(p["path"]):
        changed = module.set_fs_attributes_if_different(file_args, changed)
    module.exit_json(changed=changed, path=p["path"])


if __name__ == "__main__":
    main()