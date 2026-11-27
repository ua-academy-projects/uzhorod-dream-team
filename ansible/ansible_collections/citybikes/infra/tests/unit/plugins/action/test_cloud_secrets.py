"""Unit tests of the action plugin citybikes.infra.cloud_secrets, without the clouds (HTTP and boto3 are faked).
Run from ansible/:  python -m pytest ansible_collections/citybikes/infra/tests/unit"""

import importlib.util
import os
import unittest

PLUGIN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), *[".."] * 4, "plugins", "action", "cloud_secrets.py")
spec = importlib.util.spec_from_file_location("cloud_secrets", PLUGIN_FILE)
cloud_secrets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud_secrets)


class Response:
    def __init__(self, body):
        self.body, self.ok, self.status_code = body, True, 200

    def json(self):
        return self.body


class GcpSession:
    """Two pages of secrets; records the filter it was asked for."""

    def __init__(self):
        self.params = []

    def get(self, url, params):
        self.params.append(dict(params))
        if "pageToken" not in params:
            return Response({"secrets": [{"name": "projects/123/secrets/citybikes-ssh-host-key"}], "nextPageToken": "p2"})
        return Response({"secrets": [{"name": "projects/123/secrets/citybikes-db-password"}]})


class AwsClient:
    def get_paginator(self, name):
        assert name == "list_secrets"
        return self

    def paginate(self, Filters):
        self.filters = Filters
        yield {"SecretList": [
            {"Name": "citybikes-ssh-host-key", "Tags": [{"Key": "app", "Value": "citybikes"}]},
            # the API filters key and value apart: this one has app=other and some tag with the value citybikes
            {"Name": "other-secret", "Tags": [{"Key": "app", "Value": "other"}, {"Key": "team", "Value": "citybikes"}]},
        ]}
        yield {"SecretList": [{"Name": "citybikes-db-password", "Tags": [{"Key": "app", "Value": "citybikes"}]}]}


class Tests(unittest.TestCase):
    def test_gcp_by_label_every_page_names_only(self):
        session = GcpSession()
        self.assertEqual(cloud_secrets.gcp_names(session, "proj", "citybikes"), ["citybikes-db-password", "citybikes-ssh-host-key"])
        self.assertEqual(session.params[0]["filter"], "labels.app=citybikes")
        self.assertEqual(session.params[1]["pageToken"], "p2")

    def test_aws_by_exactly_the_tag(self):
        client = AwsClient()
        self.assertEqual(cloud_secrets.aws_names(client, "citybikes"), ["citybikes-db-password", "citybikes-ssh-host-key"])


if __name__ == "__main__":
    unittest.main()
