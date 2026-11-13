from __future__ import annotations

import traceback

GOOGLE_IMP_ERR = None
try:
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account
except ImportError:
    AuthorizedSession = None
    service_account = None
    GOOGLE_IMP_ERR = traceback.format_exc()

HAS_GOOGLE = GOOGLE_IMP_ERR is None
API_ENDPOINT = "https://compute.googleapis.com"
SCOPES = ["https://www.googleapis.com/auth/compute"]


class GceApiError(Exception):
    pass


def api_error(response, url):
    try:
        message = response.json()["error"]["message"]
    except (ValueError, KeyError, TypeError):
        message = response.text.strip()[:500]
    return GceApiError("%s %s: %s" % (response.status_code, url, message))


def credentials_from_file(path, scopes=None):
    return service_account.Credentials.from_service_account_file(path, scopes=scopes or SCOPES)


def authorized_session(path, scopes=None):
    return AuthorizedSession(credentials_from_file(path, scopes))


def compute_url(endpoint, *parts):
    return endpoint.rstrip("/") + "/compute/v1/" + "/".join(parts)


def list_all(session, url, params=None):
    query = dict(params or {})
    items = []
    while True:
        response = session.get(url, params=dict(query))
        if response.status_code >= 400:
            raise api_error(response, url)
        page = response.json()
        items.extend(page.get("items", []))
        token = page.get("nextPageToken")
        if not token:
            return items
        query["pageToken"] = token
