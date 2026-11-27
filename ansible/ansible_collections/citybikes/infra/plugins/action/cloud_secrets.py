# -*- coding: utf-8 -*-
"""Action plugin citybikes.infra.cloud_secrets: the names of the project's secrets in one cloud, asked of the cloud
itself (they carry the label/tag app=<prefix>). Ansible knows nothing of Terraform: whatever made the secrets, the
cloud says which there are. Read only; never a value."""

import json
import os

from ansible.errors import AnsibleActionFail
from ansible.plugins.action import ActionBase

GCP_LIST = "https://secretmanager.googleapis.com/v1/projects/{project}/secrets"


def gcp_names(session, project, prefix):
    """GCP: Secret Manager filtered by the label app=<prefix>, every page."""
    names, token = [], None
    while True:
        params = {"filter": "labels.app=%s" % prefix, "pageSize": 100}
        if token:
            params["pageToken"] = token
        response = session.get(GCP_LIST.format(project=project), params=params)
        if not response.ok:
            raise AnsibleActionFail("GCP Secret Manager: HTTP %s" % response.status_code)
        body = response.json()
        names += [secret["name"].rsplit("/", 1)[1] for secret in body.get("secrets", [])]
        token = body.get("nextPageToken")
        if not token:
            return sorted(names)


def aws_names(client, prefix):
    """AWS: Secrets Manager, the secrets with exactly the tag app=<prefix> (the API filters key and value apart)."""
    names = []
    filters = [{"Key": "tag-key", "Values": ["app"]}, {"Key": "tag-value", "Values": [prefix]}]
    for page in client.get_paginator("list_secrets").paginate(Filters=filters):
        for secret in page["SecretList"]:
            if {"Key": "app", "Value": prefix} in secret.get("Tags", []):
                names.append(secret["Name"])
    return sorted(names)


def gcp_session():
    """The key of infra/bootstrap (GOOGLE_APPLICATION_CREDENTIALS); the project is the one of the key."""
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account

    path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not path:
        raise AnsibleActionFail("GOOGLE_APPLICATION_CREDENTIALS is not set: source infra/bootstrap/terraform.env")
    with open(path, encoding="utf-8") as f:
        project = json.load(f)["project_id"]
    session = AuthorizedSession(service_account.Credentials.from_service_account_file(
        path, scopes=["https://www.googleapis.com/auth/cloud-platform"]))
    return session, project


def aws_client(region):
    """The profile of terraform.env, checked to be the project's account (never this machine's default profile)."""
    import boto3

    profile, account = os.environ.get("AWS_PROFILE"), os.environ.get("TF_VAR_aws_account_id")
    if not profile or not account:
        raise AnsibleActionFail("AWS_PROFILE and TF_VAR_aws_account_id must be set: source infra/bootstrap/terraform.env")
    session = boto3.Session(region_name=region)
    found = session.client("sts").get_caller_identity()["Account"]
    if found != account:
        raise AnsibleActionFail("AWS_PROFILE %s is account %s, not the project's %s" % (profile, found, account))
    return session.client("secretsmanager")


class ActionModule(ActionBase):
    TRANSFERS_FILES = False

    def run(self, tmp=None, task_vars=None):
        result = super().run(tmp, task_vars)
        _, args = self.validate_argument_spec(argument_spec=dict(
            cloud=dict(type="str", required=True, choices=["gcp", "aws"]),
            prefix=dict(type="str", required=True),
            region=dict(type="str", required=False),
        ))
        if args["cloud"] == "gcp":
            session, project = gcp_session()
            names = gcp_names(session, project, args["prefix"])
        else:
            if not args.get("region"):
                raise AnsibleActionFail("region is required for aws")
            names = aws_names(aws_client(args["region"]), args["prefix"])
        result.update(changed=False, cloud=args["cloud"], names=names)
        return result
