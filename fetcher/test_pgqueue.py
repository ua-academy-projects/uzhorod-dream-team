import contextlib
import json
import unittest
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch

import pgqueue
from weather import WeatherError

SETTINGS = pgqueue.QueueSettings(database_url="unused", poll_seconds=5, lease_seconds=60, max_attempts=5)
RECORD = {
    "city": "Lviv",
    "temperature_c": 8.1,
    "observed_at": "2026-10-15T21:00:00Z",
    "fetched_at": "2026-10-15T21:00:30Z",
}


def make_lease(attempts=1, age=timedelta(seconds=10), body=None):
    if body is None:
        body = json.dumps({"request_id": "REQ1", "requested_at": "2026-10-15T21:00:00Z"})
    return pgqueue.Lease(
        msg_id=7,
        attempts=attempts,
        enqueued_at=datetime.now(timezone.utc) - age,
        body=body,
    )


class WhatToDoTests(unittest.TestCase):
    def test_fresh_request_is_processed(self):
        lease = make_lease()
        self.assertEqual(pgqueue.what_to_do(lease, lease.enqueued_at + timedelta(seconds=10), 5), pgqueue.PROCESS)

    def test_fifth_attempt_is_still_processed(self):
        self.assertEqual(pgqueue.what_to_do(make_lease(attempts=5), datetime.now(timezone.utc), 5),
                         pgqueue.PROCESS)

    def test_sixth_attempt_is_too_many(self):
        self.assertEqual(pgqueue.what_to_do(make_lease(attempts=6), datetime.now(timezone.utc), 5),
                         pgqueue.TOO_MANY_ATTEMPTS)

    def test_request_older_than_five_minutes_expires(self):
        lease = make_lease(age=timedelta(minutes=5, seconds=1))
        self.assertEqual(pgqueue.what_to_do(lease, datetime.now(timezone.utc), 5), pgqueue.EXPIRED)


class FinishTests(unittest.TestCase):
    """finish with a fake connection: which statements are run and what is returned."""

    class FakeConn:
        def __init__(self, read_ct):
            self.read_ct = read_ct  # None: the request is not in the queue any more
            self.statements = []

        def transaction(self):
            return contextlib.nullcontext()

        def execute(self, sql, params=None):
            self.statements.append(" ".join(sql.split()))
            row = None if self.read_ct is None else (self.read_ct,)
            return SimpleNamespace(fetchone=lambda: row)

    def test_own_lease_removes_request_and_sends_answer(self):
        conn = self.FakeConn(read_ct=1)
        self.assertEqual(pgqueue.finish(conn, make_lease(attempts=1), b'{"ok": true}'), pgqueue.DONE)
        self.assertIn("FOR UPDATE", conn.statements[0])
        self.assertEqual(conn.statements[1:], ["SELECT pgmq.delete(%s, %s::bigint)",
                                               "SELECT pgmq.send(%s, %s::jsonb)"])

    def test_without_answer_only_removes(self):
        conn = self.FakeConn(read_ct=6)
        self.assertEqual(pgqueue.finish(conn, make_lease(attempts=6), None), pgqueue.REMOVED)
        self.assertEqual(conn.statements[1:], ["SELECT pgmq.delete(%s, %s::bigint)"])

    def test_request_taken_again_is_not_touched(self):
        # Another read happened after ours: read_ct grew from 1 to 2.
        conn = self.FakeConn(read_ct=2)
        self.assertEqual(pgqueue.finish(conn, make_lease(attempts=1), b"{}"), pgqueue.LEASE_LOST)
        self.assertEqual(len(conn.statements), 1)  # no delete, no send

    def test_request_already_removed_is_not_touched(self):
        conn = self.FakeConn(read_ct=None)
        self.assertEqual(pgqueue.finish(conn, make_lease(), b"{}"), pgqueue.LEASE_LOST)
        self.assertEqual(len(conn.statements), 1)


class HandleOneTests(unittest.TestCase):
    """claim and finish are replaced: the tests check what Fetcher decides and sends."""

    def run_handle(self, lease, finish_result=pgqueue.DONE, fetch=None):
        calls = {"fetch": 0, "finish": []}

        def fake_fetch():
            calls["fetch"] += 1
            if fetch is not None:
                return fetch()
            return RECORD

        def fake_finish(conn, got_lease, response):
            calls["finish"].append((got_lease, response))
            return pgqueue.REMOVED if response is None else finish_result

        with patch("pgqueue.claim", return_value=lease), patch("pgqueue.finish", side_effect=fake_finish):
            handled = pgqueue.handle_one(None, SETTINGS, fake_fetch)
        return handled, calls

    def test_no_free_request(self):
        handled, calls = self.run_handle(None)
        self.assertFalse(handled)
        self.assertEqual(calls["fetch"], 0)
        self.assertEqual(calls["finish"], [])

    def test_request_is_answered_with_own_lease(self):
        lease = make_lease()
        handled, calls = self.run_handle(lease)
        self.assertTrue(handled)
        self.assertEqual(calls["fetch"], 1)
        [(got_lease, response)] = calls["finish"]
        # Finished with exactly the lease that was taken (the same read_ct).
        self.assertIs(got_lease, lease)
        answer = json.loads(response)
        self.assertEqual(answer, {"request_id": "REQ1", "ok": True, "record": RECORD})

    def test_open_meteo_error_gives_answer_without_weather(self):
        def broken():
            raise WeatherError("timeout")

        handled, calls = self.run_handle(make_lease(), fetch=broken)
        [(_, response)] = calls["finish"]
        answer = json.loads(response)
        self.assertFalse(answer["ok"])
        self.assertNotIn("record", answer)

    def test_lost_lease_is_only_logged(self):
        with self.assertLogs("fetcher", level="WARNING") as logs:
            handled, calls = self.run_handle(make_lease(), finish_result=pgqueue.LEASE_LOST)
        self.assertTrue(handled)
        self.assertEqual(len(calls["finish"]), 1)  # no second attempt to write the answer
        self.assertIn("Оренду запиту REQ1 втрачено", "\n".join(logs.output))

    def test_too_many_attempts_removed_without_fetch(self):
        handled, calls = self.run_handle(make_lease(attempts=6))
        self.assertTrue(handled)
        self.assertEqual(calls["fetch"], 0)
        self.assertEqual([response for _, response in calls["finish"]], [None])

    def test_expired_request_removed_without_fetch(self):
        _, calls = self.run_handle(make_lease(age=timedelta(minutes=6)))
        self.assertEqual(calls["fetch"], 0)
        self.assertEqual([response for _, response in calls["finish"]], [None])

    def test_broken_request_removed_without_fetch(self):
        for body in ("[]", '{"no_id": 1}'):
            _, calls = self.run_handle(make_lease(body=body))
            self.assertEqual(calls["fetch"], 0)
            self.assertEqual([response for _, response in calls["finish"]], [None])


if __name__ == "__main__":
    unittest.main()
