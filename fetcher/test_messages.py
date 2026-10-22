import json
import unittest

from messages import InvalidMessage, build_response, parse_request
from weather import WeatherError


class ParseRequestTests(unittest.TestCase):
    def test_returns_request_id(self):
        body = b'{"request_id": "abc-1", "requested_at": "2026-10-11T15:00:00Z"}'

        self.assertEqual(parse_request(body), "abc-1")

    def test_not_json_is_invalid(self):
        with self.assertRaises(InvalidMessage):
            parse_request(b"hello")

    def test_missing_request_id_is_invalid(self):
        with self.assertRaises(InvalidMessage):
            parse_request(b'{"requested_at": "2026-10-11T15:00:00Z"}')

    def test_json_list_is_invalid(self):
        with self.assertRaises(InvalidMessage):
            parse_request(b'["abc-1"]')


class BuildResponseTests(unittest.TestCase):
    def test_success_contains_record(self):
        record = {
            "city": "Lviv",
            "temperature_c": 12.1,
            "observed_at": "2026-10-11T15:00:00Z",
            "fetched_at": "2026-10-11T15:01:02Z",
        }

        response = json.loads(build_response("abc-1", lambda: record))

        self.assertEqual(response, {"request_id": "abc-1", "ok": True, "record": record})

    def test_weather_error_gives_error_without_record(self):
        def failing_fetch():
            raise WeatherError("Open-Meteo timeout")

        response = json.loads(build_response("abc-1", failing_fetch))

        self.assertEqual(response["request_id"], "abc-1")
        self.assertFalse(response["ok"])
        self.assertIn("error", response)
        self.assertNotIn("record", response)


if __name__ == "__main__":
    unittest.main()
