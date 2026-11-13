#!/usr/bin/python

from __future__ import annotations

DOCUMENTATION = r"""
---
module: gce_ssh_key
short_description: Manage one user's entry in the ssh-keys metadata of a GCE instance
description:
  - Adds, replaces or removes the C(ssh-keys) metadata lines of one user on one Compute Engine instance.
  - Lines of other users are kept as they are, so keys added by C(gcloud compute ssh) survive.
  - A present entry has the form C(USER:KEY google-ssh {"userName":"USER","expireOn":"TIME"}) when O(expire_on) is set,
    otherwise C(USER:KEY). The comment of the public key is dropped.
  - The update uses the metadata fingerprint, so a concurrent metadata change makes the call fail instead of being overwritten.
  - The guest agent creates the user with sudo when the key appears and removes the key when the entry disappears.
    Expired keys are not accepted for new connections but stay in metadata until removed.
version_added: 1.0.0
author:
  - ISS position tracker (@iss-position-tracker)
options:
  project:
    description: Project ID.
    type: str
    required: true
  zone:
    description: Zone of the instance.
    type: str
    required: true
  instance:
    description: Instance name.
    type: str
    required: true
  user:
    description: User name of the entry.
    type: str
    required: true
  public_key:
    description: OpenSSH public key. Required when O(state=present).
    type: str
  expire_on:
    description: Expiration time in ISO 8601, for example C(2026-11-03T10:15:00+0000).
    type: str
  state:
    description: Whether the user's entry should exist.
    type: str
    choices: [present, absent]
    default: present
  auth_kind:
    description: Only C(serviceaccount) is supported.
    type: str
    choices: [serviceaccount]
    default: serviceaccount
  service_account_file:
    description: Path to the service account key. Defaults to the E(GCP_SERVICE_ACCOUNT_FILE) environment variable.
    type: path
    required: true
requirements:
  - google-auth
  - requests
attributes:
  check_mode:
    support: full
    description: Reports whether the metadata would change without calling setMetadata.
  diff_mode:
    support: none
    description: No diff is returned.
"""

EXAMPLES = r"""
- name: Add a temporary admin key for 15 minutes
  iss.platform.gce_ssh_key:
    project: my-project
    zone: changeme
    instance: iss-jump
    user: iss-admin
    public_key: "{{ lookup('ansible.builtin.file', '~/.ssh/id_ed25519.pub') }}"
    expire_on: "2026-11-03T10:15:00+0000"
  delegate_to: localhost

- name: Remove the key
  iss.platform.gce_ssh_key:
    project: my-project
    zone: changeme
    instance: iss-jump
    user: iss-admin
    state: absent
  delegate_to: localhost
"""

RETURN = r"""
lines_before:
  description: Number of ssh-keys lines before the change.
  returned: always
  type: int
lines_after:
  description: Number of ssh-keys lines after the change.
  returned: always
  type: int
"""

import json
import time

from ansible.module_utils.basic import AnsibleModule, env_fallback, missing_required_lib
from ansible_collections.iss.platform.plugins.module_utils.gce import (
    API_ENDPOINT,
    GOOGLE_IMP_ERR,
    AuthorizedSession,
    compute_url,
    credentials_from_file,
)

POLL_SECONDS = 2
POLL_LIMIT = 60


def render_entry(user, public_key, expire_on):
    key = " ".join(public_key.split()[:2])
    entry = "%s:%s" % (user, key)
    if expire_on:
        meta = json.dumps({"userName": user, "expireOn": expire_on}, separators=(",", ":"))
        entry += " google-ssh " + meta
    return entry


def update_ssh_keys(current, user, entry):
    prefix = user + ":"
    lines = [line for line in (current or "").splitlines() if line.strip() and not line.startswith(prefix)]
    if entry is not None:
        lines.append(entry)
    return "\n".join(lines)


def wait_for_operation(module, session, url):
    for attempt in range(POLL_LIMIT):
        if attempt:
            time.sleep(POLL_SECONDS)
        response = session.get(url)
        response.raise_for_status()
        operation = response.json()
        if operation.get("status") == "DONE":
            errors = operation.get("error", {}).get("errors", [])
            if errors:
                module.fail_json(msg="setMetadata failed: %s" % "; ".join(e.get("message", "") for e in errors))
            return
    module.fail_json(msg="setMetadata did not finish in %d seconds" % (POLL_SECONDS * POLL_LIMIT))


def main():
    module = AnsibleModule(
        argument_spec=dict(
            project=dict(type="str", required=True),
            zone=dict(type="str", required=True),
            instance=dict(type="str", required=True),
            user=dict(type="str", required=True),
            public_key=dict(type="str"),
            expire_on=dict(type="str"),
            state=dict(type="str", choices=["present", "absent"], default="present"),
            auth_kind=dict(type="str", choices=["serviceaccount"], default="serviceaccount"),
            service_account_file=dict(type="path", required=True, fallback=(env_fallback, ["GCP_SERVICE_ACCOUNT_FILE"])),
        ),
        required_if=[("state", "present", ["public_key"])],
        supports_check_mode=True,
    )
    if GOOGLE_IMP_ERR is not None:
        module.fail_json(msg=missing_required_lib("google-auth and requests"), exception=GOOGLE_IMP_ERR)

    p = module.params
    session = AuthorizedSession(credentials_from_file(p["service_account_file"]))
    base = compute_url(API_ENDPOINT, "projects", p["project"], "zones", p["zone"])
    url = "%s/instances/%s" % (base, p["instance"])

    response = session.get(url)
    response.raise_for_status()
    metadata = response.json().get("metadata", {})
    items = metadata.get("items", [])
    current = next((i.get("value", "") for i in items if i.get("key") == "ssh-keys"), "")

    entry = render_entry(p["user"], p["public_key"], p["expire_on"]) if p["state"] == "present" else None
    updated = update_ssh_keys(current, p["user"], entry)
    before = [line for line in current.splitlines() if line.strip()]
    result = dict(
        changed=updated != "\n".join(before),
        lines_before=len(before),
        lines_after=len(updated.splitlines()),
    )
    if not result["changed"] or module.check_mode:
        module.exit_json(**result)

    new_items = [i for i in items if i.get("key") != "ssh-keys"]
    if updated:
        new_items.append({"key": "ssh-keys", "value": updated})
    response = session.post(url + "/setMetadata", json={"fingerprint": metadata.get("fingerprint"), "items": new_items})
    response.raise_for_status()
    wait_for_operation(module, session, "%s/operations/%s" % (base, response.json()["name"]))
    module.exit_json(**result)


if __name__ == "__main__":
    main()
