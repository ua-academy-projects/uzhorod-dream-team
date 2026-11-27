"""Unit tests of the action plugin citybikes.infra.aws_secret, without AWS (the boto3 client is faked).
Run from ansible/:  python -m pytest ansible_collections/citybikes/infra/tests/unit"""

import importlib.util
import os
import sys
import types
import unittest
from unittest import mock

PLUGIN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), *[".."] * 4, "plugins", "action", "aws_secret.py")
spec = importlib.util.spec_from_file_location("aws_secret", PLUGIN_FILE)
aws_secret = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aws_secret)


# botocore's ClientError, faked when botocore is not installed (the tests never call AWS)
try:
    from botocore.exceptions import ClientError
except ImportError:
    class ClientError(Exception):
        def __init__(self, error_response, operation_name):
            super().__init__(error_response["Error"]["Code"])
            self.response = error_response

    botocore = types.ModuleType("botocore")
    botocore.exceptions = types.ModuleType("botocore.exceptions")
    botocore.exceptions.ClientError = ClientError
    sys.modules.update({"botocore": botocore, "botocore.exceptions": botocore.exceptions})


def error(code):
    return ClientError({"Error": {"Code": code, "Message": code}}, "Operation")


class FakeClient:
    def __init__(self, exists=True, value=None, denied=False):
        self.exists, self.value, self.denied = exists, value, denied

    def describe_secret(self, SecretId):
        if self.denied:
            raise error("AccessDeniedException")
        if not self.exists:
            raise error("ResourceNotFoundException")
        return {"Name": SecretId}

    def get_secret_value(self, SecretId):
        if self.value is None:
            raise error("ResourceNotFoundException")
        return {"SecretString": self.value}


class CurrentValueTests(unittest.TestCase):
    def test_no_version_yet_is_no_value(self):
        self.assertIsNone(aws_secret.current_value(FakeClient(), "citybikes-db-password"))

    def test_the_current_value(self):
        self.assertEqual(aws_secret.current_value(FakeClient(value="s3cret"), "citybikes-db-password"), "s3cret")

    def test_a_missing_secret_says_terraform_first(self):
        with self.assertRaises(aws_secret.AnsibleActionFail) as e:
            aws_secret.current_value(FakeClient(exists=False), "citybikes-db-password")
        self.assertIn("terraform apply", str(e.exception))

    def test_other_errors_name_the_code_only(self):
        with self.assertRaises(aws_secret.AnsibleActionFail) as e:
            aws_secret.current_value(FakeClient(denied=True), "citybikes-db-password")
        self.assertIn("AccessDeniedException", str(e.exception))


class AccountTests(unittest.TestCase):
    def test_no_profile_no_aws(self):
        with mock.patch.dict(os.environ, {}, clear=True), self.assertRaises(aws_secret.AnsibleActionFail) as e:
            fake_boto3 = types.ModuleType("boto3")
            with mock.patch.dict(sys.modules, {"boto3": fake_boto3}):
                aws_secret.client_for("eu-north-1")
        self.assertIn("AWS_PROFILE", str(e.exception))

    def test_another_account_is_refused(self):
        class Session:
            def __init__(self, region_name):
                pass

            def client(self, name):
                return types.SimpleNamespace(get_caller_identity=lambda: {"Account": "999999999999"})

        fake_boto3 = types.SimpleNamespace(Session=Session)
        env = {"AWS_PROFILE": "default", "TF_VAR_aws_account_id": "051251469645"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.dict(sys.modules, {"boto3": fake_boto3}), \
                self.assertRaises(aws_secret.AnsibleActionFail) as e:
            aws_secret.client_for("eu-north-1")
        self.assertIn("not the project's", str(e.exception))


if __name__ == "__main__":
    unittest.main()
