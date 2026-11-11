# -*- coding: utf-8 -*-
# The documentation of the action plugin citybikes.infra.gcp_ssh_key (plugins/action/gcp_ssh_key.py does the work).

DOCUMENTATION = r"""
module: gcp_ssh_key
short_description: A public SSH key on a VM for a few minutes (metadata ssh-keys with expireOn)
description:
  - Writes the key into the metadata C(ssh-keys) of the VM with an expiry. The Google guest agent on the VM adds it
    to the user's authorized_keys and takes it out again when it expires.
  - C(ssh-keys) belongs to Ansible. Every run keeps the keys that are still valid and drops the expired and the
    permanent ones. Every other metadata item of the VM stays as it is.
  - Who we are comes from GOOGLE_APPLICATION_CREDENTIALS (a key file), the project is the one of the key.
options:
  instance: {description: The VM, e.g. citybikes-db., type: str, required: true}
  zone: {description: Its zone., type: str, required: true}
  user: {description: The user on the VM., type: str, required: true}
  public_key: {description: The public key (one line of a .pub file)., type: str, required: true}
  ttl_minutes: {description: For how many minutes., type: int, default: 15}
requirements: [google-auth, requests]
"""