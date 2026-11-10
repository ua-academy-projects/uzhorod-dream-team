# -*- coding: utf-8 -*-

DOCUMENTATION = r"""
module: gcp_sql_user
short_description: A Cloud SQL user whose password is the value of a secret (a wrapper around google.cloud.gcp_sql_user)
description:
  - Creates the user (with google.cloud.gcp_sql_user) when it is not there.
  - Sets its password again when the secret has a new version. Which version the password is, is kept in the
    label C(sql-user-version) of the secret, so a run with an unchanged secret changes nothing.
  - The password is read from Secret Manager by the plugin itself. It is never an argument, shown or returned.
  - Who we are comes from GOOGLE_APPLICATION_CREDENTIALS (a key file), the project is the one of the key.
options:
  instance:
    description: The Cloud SQL instance, e.g. citybikes-pg.
    type: str
    required: true
  name:
    description: The user, e.g. citybikes_app.
    type: str
    required: true
  password_secret:
    description: The id of the secret with the password, e.g. citybikes-db-password.
    type: str
    required: true
requirements: [google-auth, requests]
"""

EXAMPLES = r"""
- name: The user of the application
  citybikes.infra.gcp_sql_user:
    instance: citybikes-pg
    name: citybikes_app
    password_secret: citybikes-db-password
"""