"""Unit tests of gcp_secret_file, without GCP (the HTTP calls are faked).
Run from ansible/:  python -m pytest ansible_collections/citybikes/infra/tests/unit"""

import base64
import json
import os
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, *[".."] * 7)))  # the folder that holds ansible_collections

from ansible_collections.citybikes.infra.plugins.modules import gcp_secret_file  # noqa: E402


def payload(value):
    return json.dumps({"payload": {"data": base64.b64encode(value.encode()).decode()}})


class RenderTests(unittest.TestCase):
    def test_env_for_docker_compose(self):
        self.assertEqual(gcp_secret_file.render("env", {"A": "x$y", "B": "z"}), "A='x$y'\nB='z'\n")

    def test_envfile_for_docker_run(self):
        self.assertEqual(gcp_secret_file.render("envfile", {"PGPASSWORD": "p#w"}), "PGPASSWORD=p#w\n")

    def test_ini_for_certbot(self):
        self.assertEqual(gcp_secret_file.render("ini", {"dns_cloudflare_api_token": "t"}), "dns_cloudflare_api_token = t\n")

    def test_raw_gets_a_final_newline_once(self):
        self.assertEqual(gcp_secret_file.render("raw", {"key": "KEY"}), "KEY\n")
        self.assertEqual(gcp_secret_file.render("raw", {"key": "KEY\n"}), "KEY\n")

    def test_values_that_would_break_the_file_are_refused(self):
        for file_format, values in (("env", {"A": "it's"}), ("envfile", {"A": "two\nlines"}), ("raw", {"a": "1", "b": "2"})):
            with self.subTest(file_format), self.assertRaises(gcp_secret_file.SecretError):
                gcp_secret_file.render(file_format, values)


class ReadSecretTests(unittest.TestCase):
    def test_reads_the_latest_value(self):
        with mock.patch.object(gcp_secret_file, "get", return_value=payload("s3cret")) as get:
            self.assertEqual(gcp_secret_file.read_secret("p", "citybikes-db-password", "tok"), "s3cret")
        url, headers = get.call_args[0]
        self.assertTrue(url.endswith("/projects/p/secrets/citybikes-db-password/versions/latest:access"))
        self.assertEqual(headers, {"Authorization": "Bearer tok"})

    def test_clear_messages(self):
        for code, words in ((404, "no value yet"), (403, "may not read")):
            error = gcp_secret_file.HTTPError("url", code, "error", {}, None)
            with self.subTest(code), mock.patch.object(gcp_secret_file, "get", side_effect=error):
                with self.assertRaisesRegex(gcp_secret_file.SecretError, words):
                    gcp_secret_file.read_secret("p", "s", "tok")


class WriteFileTests(unittest.TestCase):
    def setUp(self):
        self.path = os.path.join(tempfile.mkdtemp(), ".env")
        self.module = types.SimpleNamespace(check_mode=False, atomic_move=os.replace)

    def test_written_once_then_unchanged(self):
        self.assertTrue(gcp_secret_file.write_if_changed(self.module, self.path, "A='1'\n"))
        self.assertFalse(gcp_secret_file.write_if_changed(self.module, self.path, "A='1'\n"))
        self.assertTrue(gcp_secret_file.write_if_changed(self.module, self.path, "A='2'\n"))
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_check_mode_writes_nothing(self):
        self.module.check_mode = True
        self.assertTrue(gcp_secret_file.write_if_changed(self.module, self.path, "A='1'\n"))
        self.assertFalse(os.path.exists(self.path))


if __name__ == "__main__":
    unittest.main()
    