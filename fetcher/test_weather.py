import unittest
from unittest.mock import Mock, patch

from weather import WeatherError, fetch_current_temperature


class FetchCurrentTemperatureTests(unittest.TestCase):
    @patch("weather.httpx.get")
    def test_invalid_observation_time_raises_weather_error(self, get):
        response = Mock()
        response.json.return_value = {
            "current": {
                "temperature_2m": 12.1,
                "time": "not-a-valid-time",
            }
        }
        get.return_value = response

        with self.assertRaises(WeatherError):
            fetch_current_temperature("Lviv", 49.84, 24.03, 10)

    @patch("weather.httpx.get")
    def test_valid_observation_time_is_returned_in_utc(self, get):
        response = Mock()
        response.json.return_value = {
            "current": {
                "temperature_2m": 12.1,
                "time": "2026-10-05T02:15:00+03:00",
            }
        }
        get.return_value = response

        record = fetch_current_temperature("Lviv", 49.84, 24.03, 10)

        self.assertEqual(record["observed_at"], "2026-10-04T23:15:00Z")


if __name__ == "__main__":
    unittest.main()
