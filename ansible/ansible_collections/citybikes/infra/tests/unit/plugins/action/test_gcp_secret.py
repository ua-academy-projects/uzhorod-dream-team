"""Unit tests of the action plugin citybikes.infra.gcp_secret, without GCP (the HTTP session is faked).
Run from ansible/:  python -m pytest ansible_collections/citybikes/infra/tests/unit"""

import base64
import importlib.util
import os
import unittest

PLUGIN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), *[".."] * 4, "plugins", "action", "gcp_secret.py")
spec = importlib.util.spec_from_file_location("gcp_secret", PLUGIN_FILE)
gcp_secret = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gcp_secret)

URL = "https://secretmanager.googleapis.com/v1/projects/p/secrets/citybikes-db-password"


class Response:
    def __init__(self, status, body=None):
        self.status_code, self.body = status, body or {}
        self.ok = status < 400

    def json(self):
        return self.body


class FakeSession:
    """A secret in Secret Manager: exists or not, its versions (values, the last is "latest")."""

    def __init__(self, exists=True, versions=(), latest_state="ENABLED"):
        self.exists, self.versions, self.latest_state = exists, list(versions), latest_state
        self.added = []

    def get(self, url):
        if not self.exists:
            return Response(404, {"error": {"message": "Secret not found"}})
        if url == URL:
            return Response(200, {"name": URL})
        if url == URL + "/versions/latest:access":
            if not self.versions:
                return Response(404, {"error": {"message": "not found or has no versions"}})
            if self.latest_state != "ENABLED":
                return Response(400, {"error": {"message": "is in DESTROYED state"}})
            return Response(200, {"payload": {"data": base64.b64encode(self.versions[-1].encode()).decode()}})
        raise AssertionError(url)

    def post(self, url, json):
        assert url == URL + ":addVersion", url
        value = base64.b64decode(json["payload"]["data"]).decode()
        self.versions.append(value)
        self.added.append(value)
        return Response(200)


class LatestValueTests(unittest.TestCase):
    def test_a_secret_with_no_version_yet_has_no_value(self):
        self.assertIsNone(gcp_secret.latest_value(FakeSession(), URL))

    def test_a_destroyed_latest_version_is_no_value(self):
        self.assertIsNone(gcp_secret.latest_value(FakeSession(versions=["x"], latest_state="DESTROYED"), URL))

    def test_the_latest_value(self):
        self.assertEqual(gcp_secret.latest_value(FakeSession(versions=["old", "new"]), URL), "new")

    def test_a_missing_secret_says_terraform_first(self):
        with self.assertRaises(gcp_secret.AnsibleActionFail) as error:
            gcp_secret.latest_value(FakeSession(exists=False), URL)
        self.assertIn("terraform apply", str(error.exception))


class AddVersionTests(unittest.TestCase):
    def test_the_value_goes_in_base64(self):
        session = FakeSession()
        gcp_secret.add_version(session, URL, "pässword")
        self.assertEqual(session.added, ["pässword"])


if __name__ == "__main__":
    unittest.main()
