# -*- coding: utf-8 -*-
"""Action plugin citybikes.infra.aws_secret: the value of a secret in AWS Secrets Manager, with boto3 on this
machine. It compares the value with the current one and writes a new version only when it differs. It never
CREATES a secret: Terraform makes them (empty), only their values are ours. A secret with no version yet simply
has no value yet. Who we are: the AWS profile of infra/bootstrap/terraform.env, and only in the project's account."""

import os

from ansible.errors import AnsibleActionFail
from ansible.plugins.action import ActionBase


def client_for(region):
    """Secrets Manager with the profile of terraform.env, checked to be the project's account (never the default
    profile of this machine, which may be another account)."""
    import boto3

    if not os.environ.get("AWS_PROFILE"):
        raise AnsibleActionFail("AWS_PROFILE is not set: source infra/bootstrap/terraform.env")
    session = boto3.Session(region_name=region)
    account = os.environ.get("TF_VAR_aws_account_id")
    if not account:
        raise AnsibleActionFail("TF_VAR_aws_account_id is not set: source infra/bootstrap/terraform.env")
    found = session.client("sts").get_caller_identity()["Account"]
    if found != account:
        raise AnsibleActionFail("AWS_PROFILE %s is account %s, not the project's %s" % (os.environ["AWS_PROFILE"], found, account))
    return session.client("secretsmanager")


def code_of(error):
    return getattr(error, "response", {}).get("Error", {}).get("Code", "")


def current_value(client, name):
    """The current value, or None when there is none yet. A missing secret is an error: Terraform makes them."""
    from botocore.exceptions import ClientError

    try:
        client.describe_secret(SecretId=name)
    except ClientError as error:
        if code_of(error) == "ResourceNotFoundException":
            raise AnsibleActionFail("The secret %s does not exist: make it with the infrastructure first (terraform apply)" % name)
        raise AnsibleActionFail("%s: %s" % (name, code_of(error) or "error"))
    try:
        return client.get_secret_value(SecretId=name)["SecretString"]
    except ClientError as error:
        if code_of(error) == "ResourceNotFoundException":  # no version yet
            return None
        raise AnsibleActionFail("%s: %s" % (name, code_of(error) or "error"))


class ActionModule(ActionBase):
    TRANSFERS_FILES = False

    def run(self, tmp=None, task_vars=None):
        result = super().run(tmp, task_vars)
        _, args = self.validate_argument_spec(argument_spec=dict(
            name=dict(type="str", required=True),
            value=dict(type="str", required=True, no_log=True),
            region=dict(type="str", required=True),
        ))

        client = client_for(args["region"])
        changed = current_value(client, args["name"]) != args["value"]
        if changed and not self._play_context.check_mode:
            client.put_secret_value(SecretId=args["name"], SecretString=args["value"])

        # only what says what happened: never the value
        result.update(changed=changed, name=args["name"])
        return result
