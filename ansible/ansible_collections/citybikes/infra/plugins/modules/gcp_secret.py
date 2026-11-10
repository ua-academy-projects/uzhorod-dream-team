# -*- coding: utf-8 -*-
# The documentation of the action plugin citybikes.infra.gcp_secret (plugins/action/gcp_secret.py does the work).

DOCUMENTATION = r"""
module: gcp_secret
short_description: The value of a secret in Secret Manager (a wrapper around google.cloud.gcp_secret_manager)
description:
  - Adds a new version only when the value differs from the latest one.
  - The secret must exist already. This module never creates one, it fills it in.
  - Who we are comes from GOOGLE_APPLICATION_CREDENTIALS (a key file), the project is the one of the key.
  - The value is never shown or returned.
options:
  name:
    description: The id of the secret, e.g. citybikes-db-password.
    type: str
    required: true
  value:
    description: Its value.
    type: str
    required: true
requirements: [google-auth, requests]
"""

EXAMPLES = r"""
- name: The password of the database
  citybikes.infra.gcp_secret:
    name: citybikes-db-password
    value: "{{ db_password }}"
  no_log: true
"""