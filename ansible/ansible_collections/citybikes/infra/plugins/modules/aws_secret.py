# -*- coding: utf-8 -*-
# The documentation of the action plugin citybikes.infra.aws_secret (plugins/action/aws_secret.py does the work).

DOCUMENTATION = r"""
module: aws_secret
short_description: The value of a secret in AWS Secrets Manager
description:
  - Writes a new version only when the value differs from the current one.
  - The secret must exist already. This module never creates one, it fills it in.
  - Who we are comes from AWS_PROFILE (infra/bootstrap/terraform.env); it must be the account TF_VAR_aws_account_id.
  - The value is never shown or returned.
options:
  name:
    description: The name of the secret, e.g. citybikes-db-password.
    type: str
    required: true
  value:
    description: Its value.
    type: str
    required: true
  region:
    description: The region of the secret, e.g. eu-north-1.
    type: str
    required: true
requirements: [boto3]
"""

EXAMPLES = r"""
- name: The password of the database
  citybikes.infra.aws_secret:
    name: citybikes-db-password
    value: "{{ db_password }}"
    region: eu-north-1
  no_log: true
"""
