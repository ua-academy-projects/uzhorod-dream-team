# -*- coding: utf-8 -*-
# The documentation of the action plugin citybikes.infra.cloud_secrets (plugins/action/cloud_secrets.py does the work).

DOCUMENTATION = r"""
module: cloud_secrets
short_description: The names of the project's secrets in one cloud
description:
  - Asks the cloud itself which secrets carry the label (GCP) or tag (AWS) C(app=<prefix>).
  - Read only. It returns names, never a value.
  - GCP with the key of GOOGLE_APPLICATION_CREDENTIALS (its project); AWS with AWS_PROFILE, which must be the
    account TF_VAR_aws_account_id.
options:
  cloud:
    description: The cloud.
    type: str
    required: true
    choices: [gcp, aws]
  prefix:
    description: The value of the label or tag C(app), the prefix of config.json.
    type: str
    required: true
  region:
    description: The region (AWS only).
    type: str
requirements: [google-auth, requests, boto3]
"""

EXAMPLES = r"""
- name: The project's secrets in AWS
  citybikes.infra.cloud_secrets:
    cloud: aws
    prefix: citybikes
    region: eu-north-1
  register: found   # found.names
"""
